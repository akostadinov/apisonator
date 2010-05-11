require File.dirname(__FILE__) + '/../test_helper'

class ReportTest < Test::Unit::TestCase
  include TestHelpers::Integration

  def setup
    @storage = ThreeScale::Backend.storage
    @storage.flushdb

    @provider_key = 'key1001'
    @service_id = '100'
    Service.save(:provider_key => @provider_key, :id => @service_id)

    @user_key = 'key2001'
    @contract_id = '2001'
    Contract.save(:service_id => @service_id, :id => @contract_id,
                  :user_key => @user_key, :state => :live)

    @metric_id = '6001'
    Metrics.save(:service_id => @service_id, @metric_id => {:name => 'hits'})
  end

  def test_successful_report_responds_with_200
    async_post '/transactions.xml',
      :provider_key => @provider_key,
      :transactions => {0 => {:user_key => @user_key, :usage => {'hits' => 1}}} do
      assert_equal 200, last_response.status
    end
  end
  
  def test_successful_report_increments_the_stats_counters
    key_month = "stats/{service:#{@service_id}}/cinstance:#{@contract_id}/metric:#{@metric_id}/month:20100501"
    key_day   = "stats/{service:#{@service_id}}/cinstance:#{@contract_id}/metric:#{@metric_id}/day:20100510"

    Timecop.freeze(2010, 5, 10, 17, 36) do
      async_post '/transactions.xml',
        :provider_key => @provider_key,
        :transactions => {0 => {:user_key => @user_key, :usage => {'hits' => 1}}} do
        assert_equal 1, @storage.get(key_month).to_i
        assert_equal 1, @storage.get(key_day).to_i
      end
    end
  end
end
