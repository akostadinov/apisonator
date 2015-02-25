require '3scale/backend/errors'

module ThreeScale
  module Backend
    # Methods for caching
    module Cache
      include Backend::StorageKeyHelpers
      extend self

      VALID_PARAMS_FOR_CACHE = [:provider_key,
                                :service_id,
                                :app_id,
                                :app_key,
                                :user_key,
                                :user_id,
                                :referrer,
                                :redirect_url,
                                :usage]

      COMBINATION_TTL       = 3600 # 1 hour
      STATUS_TTL            = 60   # 1 minute, this is too short but we need minute information on the output :-(
      SERVICE_ID_CACHE_TTL  = 300  # 5 minutes


      ## this is a little bit dangerous, but we can live with it
      def get_service_id(provider_key)
        current_time = Time.now.getutc
        @@provider_key_2_service_id ||= Hash.new
        sid, time = @@provider_key_2_service_id[provider_key]
        if sid.nil? || (current_time-time > SERVICE_ID_CACHE_TTL)
          sid = storage.get("service/provider_key:#{provider_key}/id")
          @@provider_key_2_service_id[provider_key] = [sid, current_time] unless sid.nil?
        end
        sid
      end

      def stats
        @@stats ||= {:count => 0, :hits => 0, :last => nil}
        @@stats
      end

      def stats=(s)
        @@stats=s
      end

      def report_cache_hit
        @@stats ||= {:count => 0, :hits => 0, :last => nil}
        @@stats[:count]+=1
        @@stats[:hits]+=1
        @@stats[:last]=1
      end

      def report_cache_miss
        @@stats ||= {:count => 0, :hits => 0, :last => nil}
        @@stats[:count]+=1
        @@stats[:last]=0
      end

      def caching_enable
        storage.set("settings/caching_enabled",1)
      end

      def caching_disable
        storage.set("settings/caching_enabled",0)
      end

      def caching_enabled?
        storage.get("settings/caching_enabled")!="0"
      end

      def signature(action, params)
        key_version = "cache_combination/#{action}/"

        VALID_PARAMS_FOR_CACHE.each do |label|
          if label!=:usage || params[:usage].nil?
            key_version << "#{label}:#{params[label]}/"
          else
            params[:usage].each do |key,value|
              key_version << "#{label}:#{key}:"
            end
          end
        end
        key_version
      end

      def combination_seen(action, provider_key, params)

        key_version = nil

        if params[:service_id].nil? || params[:service_id].empty?
          #memoizing provider_key by service_id is no longer possible, because it can
          #change in the meantime, extremely unconvenient
          service_id = Service.default_id!(provider_key)
        else
          service_id = params[:service_id]
        end

        if !service_id.nil?

          key_version = signature(action, params)
          application_id = params[:app_id]
          application_id = params[:user_key] if application_id.nil?

          username = params[:user_id]

          application_id = "" if application_id.nil?
          application_id_cached = application_id.clone
          application_id_cached << ":"
          application_id_cached << params[:app_key] unless params[:app_key].nil?
          application_id_cached << ":"
          application_id_cached << params[:referrer] unless params[:referrer].nil?

          # FIXME: this needs to be done for redirect_url(??)

          if username.nil?

            cached_app_key = caching_key(service_id,:application,application_id_cached)
            version,
            ver_service,
            ver_application,
            dirty_app_xml,
            caching_enabled = storage.mget(
              key_version,
              Service.storage_key(service_id, :version),
              Application.storage_key(service_id,application_id,:version),
              cached_app_key,
              "settings/caching_enabled")

            current_version = "s:#{ver_service}/a:#{ver_application}"

          else

            cached_app_key = caching_key(service_id,:application,application_id_cached)
            cached_user_key = caching_key(service_id,:user,username)

            version,
            ver_service,
            ver_application,
            ver_user,
            dirty_app_xml,
            dirty_user_xml,
            caching_enabled = storage.mget(
              key_version,
              Service.storage_key(service_id, :version),
              Application.storage_key(service_id,application_id,:version),
              User.storage_key(service_id,username,:version),
              cached_app_key,
              cached_user_key,
              "settings/caching_enabled")

            current_version = "s:#{ver_service}/a:#{ver_application}/u:#{ver_user}"
          end

          if !version.nil? && current_version==version
            ## success, we have seen this key combination before, probably shit loads
            ## of times. And neither service, application or user have changed, or any
            ## other object that has a foreing key to service, application or user
            isknown = true

            # this does not necessarily means that the request is going to be authorized
            # it will depend on getting the status from cache. This means that this keys
            # id's combination has been seen before, and perhaps, has a status stored in
            # in the cache.

          else
            ## something has changed in service, user, application, metric, plan, etc.
            isknown = false
          end

        else
          isknown = false
        end

        combination_data = {:key => key_version, :current_version => current_version}

        ## the default of settings/caching_enabled results on true, to disable caching set
        ## settings/caching_enabled to 0
        caching_enabled = caching_enabled!="0"

        return [isknown, service_id, combination_data, dirty_app_xml, dirty_user_xml, caching_enabled]

      end


      def combination_save(data)

        unless data.nil? || data[:key].nil? || data[:current_version].nil?
          storage.pipelined do
            storage.set(data[:key],data[:current_version])
            storage.expire(data[:key],COMBINATION_TTL)
          end
        end

      end


      ## this one is hacky, handle with care. This updates the cached xml so that we can increment
      ## the current_usage. TODO: we can do limit checking here, however, the non-cached authrep does not
      ## cover this corner case either, e.g. it could be that the output is <current_value>101</current_value>
      ## and <max_value>100</max_value> and still be authorized, the next authrep with fail be limits though.
      ## This would have been much more elegant if we were caching serialized objects, but binary marshalling
      ## is extremely slow, divide performance by 2, and marshalling is faster than json, yaml, byml, et
      ## (benchmarked)

      def clean_cached_xml(app_xml_str, user_xml_str, options = {})
        split_app_xml  = split_xml(app_xml_str)
        split_user_xml = split_xml(user_xml_str)
        authorized     = xml_authorized?(split_app_xml, split_user_xml)
        merged_xml     = merge_xmls(authorized, split_app_xml, split_user_xml)

        v = merged_xml.split("|.|")
        newxmlstr = ""
        limit_violation_without_usage = false
        limit_violation_with_usage = false

        i=0
        v.each do |str|
          if (i%2==1)
            _, metric, curr_value, max_value = str.split(",")
            curr_value = curr_value.to_i
            max_value = max_value.to_i
            inc = 0
            val = nil

            if options[:usage]
              inc = options[:usage][metric].to_i
              val = ThreeScale::Backend::Aggregator::get_value_of_set_if_exists(options[:usage][metric])
            end

            unless limit_violation_without_usage
              limit_violation_without_usage = (curr_value > max_value)
            end

            unless limit_violation_with_usage
              if val
                limit_violation_with_usage = (val.to_i > max_value)
              elsif inc > 0
                limit_violation_with_usage = (curr_value + inc > max_value)
              end
            end

            if authorized && options[:add_usage_on_report]
              ## only increase if asked explicity via options[:add_usage_on_report] and if the status was
              ## authorized to begin with, otherwise we might increment on a status that is not authorized
              ## and that would look weird for the user
              if val.nil?
                str = (curr_value + inc).to_s
              else
                str = val.to_s
              end
            else
              str = curr_value.to_s
            end
          end

          newxmlstr << str
          i += 1
        end

        if authorized && (limit_violation_without_usage || limit_violation_with_usage)
          ## the cache says that the status was authorized but a violation just occured on the limits...
          ## then, just forget and let the proper way to calculate it
          violation_just_happened = true
        elsif !authorized && limit_violation_without_usage && !limit_violation_with_usage
          ## the cache says that the status was NOT authorized and there is a limit violation without summing the usage
          ## but because a negative usage or a set now it's ok, just forget the cache and the the proper way to calculate
          violation_just_happened = true
        else
          violation_just_happened = false
        end

        [newxmlstr, authorized, violation_just_happened]
      end


      ## sets all the application by id:app_key
      def set_status_in_cache_application(service_id, application, status, options ={})
        options[:anchors_for_caching] = true
        content = status.to_xml(options)
        tmp_keys = []
        keys = []

        application.keys.each do |app_key|
          tmp_keys << "#{application.id}:#{app_key}"
        end

        tmp_keys << "#{application.id}:" if application.keys.size==0

        application.referrer_filters.each do |referrer|
          tmp_keys.each do |item|
            keys << caching_key(service_id,:application,"#{item}:#{referrer}")
          end
        end

        if application.referrer_filters.size==0
          tmp_keys.each do |item|
            keys << caching_key(service_id,:application,"#{item}:")
          end
        end

        if status.authorized?
          storage.pipelined do
            keys.each do |key|
              storage.set(key,content)
              storage.expire(key,STATUS_TTL-Time.now.getutc.sec)
              storage.srem("limit_violations_set",key)
            end
          end
        else
          storage.pipelined do
            keys.each do |key|
              storage.set(key,content)
              storage.expire(key,STATUS_TTL-Time.now.getutc.sec)
              storage.sadd("limit_violations_set",key)
            end
          end
        end

      end

      def set_status_in_cache(key, status, options ={})
        options[:anchors_for_caching] = true
        if status.authorized?
          storage.pipelined do
            storage.set(key,status.to_xml(options))
            storage.expire(key,STATUS_TTL-Time.now.getutc.sec)
            storage.srem("limit_violations_set",key)
          end
        else
          ## it just violated the Limits, add to the violation set
          storage.pipelined do
            storage.set(key,status.to_xml(options))
            storage.expire(key,STATUS_TTL-Time.now.getutc.sec)
            storage.sadd("limit_violations_set",key)
          end
        end
      end

      def caching_key(service_id, type ,id)
        "cache/service:#{service_id}/#{type.to_s}:#{id}"
      end

      private

      def split_xml(xml_str = nil)
        xml_str.split("<__separator__/>") if xml_str
      end

      def xml_authorized?(split_app_xml, split_user_xml = nil)
        if split_user_xml
          app_authorized  = node_authorized?(split_app_xml.first)
          user_authorized = node_authorized?(split_user_xml.first)

          app_authorized && user_authorized
        else
          node_authorized?(split_app_xml.first)
        end
      end

      def node_authorized?(node)
        node != "0"
      end

      def merge_xmls(authorized, split_app_xml, split_user_xml = nil)
        if split_user_xml
          ## add the user usage_report segment
          split_app_xml    = split_app_xml.insert(3, split_user_xml[2])
          ## change the <status>autho <> segment if the user did not get
          ## authorized if the application was not authorized no problem
          ## because it's the default both need to be authorized, other
          ## not authorized. This might produce a collision on the reasons,
          ## but let's assume app has precedence
          split_app_xml[1] = split_user_xml[1]
        end

        ## better that v.join()
        result = ""
        for i in 1..(split_app_xml.size - 1) do
          result << split_app_xml[i].to_s
        end

        result
      end
    end
  end
end
