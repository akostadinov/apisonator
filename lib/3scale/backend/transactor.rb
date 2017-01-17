require '3scale/backend/transactor/notify_batcher'
require '3scale/backend/transactor/notify_job'
require '3scale/backend/transactor/process_job'
require '3scale/backend/transactor/report_job'
require '3scale/backend/transactor/usage_report'
require '3scale/backend/transactor/status'
require '3scale/backend/errors'
require '3scale/backend/validators'
require '3scale/backend/stats/keys'

module ThreeScale
  module Backend
    # Methods for reporting and authorizing transactions.
    module Transactor
      include Backend::StorageKeyHelpers
      include NotifyBatcher
      extend self

      def report(provider_key, service_id, transactions, context_info = {})
        service = load_service!(provider_key, service_id)

        report_enqueue(service.id, transactions, context_info)
        notify_report(provider_key, transactions.size)
      end

      def authorize(provider_key, params, extensions = {})
        do_authorize :authorize, provider_key, params, extensions
      end

      def oauth_authorize(provider_key, params, extensions = {})
        do_authorize :oauth_authorize, provider_key, params, extensions
      end

      def authrep(provider_key, params, extensions = {})
        do_authrep :authrep, provider_key, params, extensions
      end

      def oauth_authrep(provider_key, params, extensions = {})
        do_authrep :oauth_authrep, provider_key, params, extensions
      end

      def utilization(service_id, application_id)
        application = Application.load!(service_id, application_id)
        usage = load_application_usage(application, Time.now.getutc)
        status = ThreeScale::Backend::Transactor::Status.new(:application => application, :values => usage)
        ThreeScale::Backend::Validators::Limits.apply(status, {})

        max_utilization = 0
        max_record = 0

        unless status.application_usage_reports.empty?
          max_utilization, max_record = ThreeScale::Backend::Alerts.utilization(
              status.application_usage_reports, status.user_usage_reports)
        end

        max_utilization = (max_utilization * 100.to_f).round

        stats = ThreeScale::Backend::Alerts.stats(service_id, application_id)

        [status.application_usage_reports, max_record, max_utilization, stats]
      end

      private

      def validate(oauth, provider_key, report_usage, params, extensions)
        service = load_service!(provider_key, params[:service_id])
        app_id, user_id = params[:app_id], params[:user_id]
        # TODO: make sure params are nil if they are empty up the call stack so
        # that we stop these idiotic checkings.
        params[:app_id] = nil if app_id && app_id.empty?
        params[:user_id] = nil if user_id && user_id.empty?

        # Now OAuth tokens also identify users, so must check tokens anyway if
        # at least one of app or user ids is missing.
        #
        # We should probably limit the calls to OAuth methods without access
        # tokens, because they are not really OAuth otherwise. And perhaps also
        # forbid calling these endpoints with app_id and/or user_id.
        #
        # NB: so what happens if we call an OAuth method with user_key=K and
        # user_id=U? It is effectively as if app_id was given and no token would
        # need to be checked, but we do... That is not consistent. And madness.
        # Each time I try to understand this I feel I'm becoming dumber...
        #
        if oauth && (user_id.nil? || app_id.nil?)
          access_token = params[:access_token]
          access_token = nil if access_token && access_token.empty?

          if access_token.nil?
            raise ApplicationNotFound.new nil if app_id.nil?
          else
            begin
              token_appid, token_uid = OAuth::Token::Storage.get_credentials(
                access_token, service.id
              )
            rescue AccessTokenInvalid => e
              # Yep, well, er. Someone specified that it is OK to have an
              # invalid token if an app_id is specified. Somehow passing in
              # a user_key is still not enough, though...
              raise e if app_id.nil?
            end

            # We only take the token ids into account if we had no parameter ids
            # (we also update the params hash, because countless places just
            # read from them).
            if app_id.nil?
              app_id = params[:app_id] = token_appid
            end
            if user_id.nil?
              user_id = params[:user_id] = token_uid
            end
          end
          validators = Validators::OAUTH_VALIDATORS
        else
          validators = Validators::VALIDATORS
        end

        params[:user_key] = nil if params[:user_key] && params[:user_key].empty?
        application = Application.load_by_id_or_user_key!(service.id,
                                                          app_id,
                                                          params[:user_key])

        user         = load_user!(application, service, user_id)
        now          = Time.now.getutc
        usage_values = load_application_usage(application, now)
        user_usage   = load_user_usage(user, now) if user
        status_attrs = {
          user_values: user_usage,
          application: application,
          service:     service,
          oauth:       oauth,
          usage:       report_usage ? params[:usage] : nil,
          values:      usage_values,
          # hierarchy parameter adds information in the response needed
          # to derive which limits affect directly or indirectly the
          # metrics for which authorization is requested.
          hierarchy:   extensions[:hierarchy] == '1',
          user:        user,
        }

        # returns a status object
        apply_validators(validators, status_attrs, params)
      end

      def do_authorize(method, provider_key, params, extensions)
        notify_authorize(provider_key)
        validate(method == :oauth_authorize, provider_key, false, params, extensions)
      end

      def do_authrep(method, provider_key, params, extensions)
        status = begin
                   validate(method == :oauth_authrep, provider_key, true, params, extensions)
                 rescue ThreeScale::Backend::ApplicationNotFound, ThreeScale::Backend::UserNotDefined => e
                   # we still want to track these
                   notify_authorize(provider_key)
                   raise e
                 end

        service_id = status.service.id
        application_id = status.application.id
        username = status.user.username unless status.user.nil?
        usage = params[:usage]

        if (usage || params[:log]) && status.authorized?
          report_enqueue(service_id, ({ 0 => {"app_id" => application_id, "usage" => usage, "user_id" => username, "log" => params[:log]}}), {})
          notify_authrep(provider_key, usage ? usage.size : 0)
        else
          notify_authorize(provider_key)
        end

        status
      end

      def load_user!(application, service, user_id)
        user = nil

        if not (user_id.nil? || user_id.empty? || !user_id.is_a?(String))
          ## user_id on the paramters
          if application.user_required?
            user = User.load_or_create!(service, user_id)
            raise UserRequiresRegistration, service.id, user_id unless user
          end
        else
          raise UserNotDefined, application.id if application.user_required?
        end

        user
      end

      def load_service!(provider_key, id)
        id = Service.default_id!(provider_key) if id.nil? || id.empty?
        service = Service.load_by_id(id.split('-').last) || Service.load_by_id!(id)

        if service.provider_key != provider_key
          Service.default_id!(provider_key) # no need to check anything, raises if invalid provider
          raise ServiceIdInvalid, id
        end

        service
      end

      def apply_validators(validators, status_attrs, params)
        Status.new(status_attrs).tap do |st|
          validators.all? { |validator| validator.apply(st, params) }
        end
      end

      def report_enqueue(service_id, data, context_info)
        Resque.enqueue(ReportJob, service_id, data, Time.now.getutc.to_f, context_info)
      end

      def notify_authorize(provider_key)
        notify(provider_key, 'transactions/authorize'.freeze => 1)
      end

      def notify_authrep(provider_key, transactions)
        notify(provider_key, 'transactions/authorize'.freeze => 1,
                             'transactions/create_multiple'.freeze => 1,
                             'transactions'.freeze => transactions)
      end

      def notify_report(provider_key, transactions)
        notify(provider_key, 'transactions/create_multiple'.freeze => 1,
                             'transactions'.freeze => transactions)
      end

      def notify(provider_key, usage)
        ## No longer create a job, but for efficiency the notify jobs (incr stats for the master) are
        ## batched. It used to be like this:
        ## tt = Time.now.getutc
        ## Resque.enqueue(NotifyJob, provider_key, usage, encode_time(tt), tt.to_f)
        ##
        ## Basically, instead of creating a NotifyJob directly, which would trigger between 10-20 incrby
        ## we store the data of the job in redis on a list. Once there are configuration.notification_batch
        ## on the list, the worker will fetch the list, aggregate them in a single NotifyJob will all the
        ## sums done in memory and schedule the job as a NotifyJob. The advantage is that instead of having
        ## 20 jobs doing 10 incrby of +1, you will have a single job doing 10 incrby of +20
        notify_batch(provider_key, usage)
      end

      def get_pairs_and_metric_ids(usage_limits)
        pairs = []

        metric_ids = usage_limits.map do |usage_limit|
          m_id = usage_limit.metric_id
          pairs << [m_id, usage_limit.period]
          m_id
        end

        [pairs, metric_ids]
      end

      def load_usage(obj)
        pairs, metric_ids = get_pairs_and_metric_ids obj.usage_limits
        return {} if pairs.empty?

        # preloading metric names
        obj.metric_names = Metric.load_all_names(obj.service_id, metric_ids)
        keys = pairs.map(&Proc.new)
        values = {}
        pairs.zip(storage.mget(keys)) do |(metric_id, period), value|
          values[period] ||= {}
          values[period][metric_id] = value.to_i
        end
        values
      end

      def load_user_usage(user, ts)
        load_usage user do |metric_id, period|
          Stats::Keys.user_usage_value_key(user.service_id, user.username, metric_id, period, ts)
        end
      end

      def load_application_usage(application, ts)
        load_usage application do |metric_id, period|
          Stats::Keys.usage_value_key(application.service_id, application.id, metric_id, period, ts)
        end
      end

      def storage
        Storage.instance
      end
    end
  end
end
