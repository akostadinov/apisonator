require File.dirname(__FILE__) + '/../test_helper'

class TransactorTest < Test::Unit::TestCase
  include TestHelpers::EventMachine

  def setup
    @provider_key = 'key0001'
    @service_id = '1001'
    @metric_id  = '2001'

    @contract_id_one = '4001'
    @contract_id_two = '4002'

    @user_key_one = 'key4001'
    @user_key_two = 'key4002'
    
    @storage = ThreeScale::Backend.storage
    @storage.flushdb

    Service.save(:provider_key => @provider_key, :id => @service_id)

    Contract.save(:service_id => @service_id,
                  :user_key => @user_key_one,
                  :id => @contract_id_one,
                  :state => :live)
    
    Contract.save(:service_id => @service_id,
                  :user_key => @user_key_two,
                  :id => @contract_id_two,
                  :state => :live)

    Metrics.save(:service_id => @service_id, @metric_id => {:name => 'hits'})
  end
  
  def test_report_aggregates
    time = Time.now

    Aggregation.expects(:aggregate).with(:service   => @service_id,
                                         :cinstance => @contract_id_one,
                                         :timestamp => time,
                                         :usage     => {@metric_id => 1})

    Aggregation.expects(:aggregate).with(:service   => @service_id,
                                         :cinstance => @contract_id_two,
                                         :timestamp => time,
                                         :usage     => {@metric_id => 1})

    Timecop.freeze(time) do
      Transactor.report(
        @provider_key,
        {'0' => {'user_key' => @user_key_one, 'usage' => {'hits' => 1}},
         '1' => {'user_key' => @user_key_two, 'usage' => {'hits' => 1}}})
    end
  end
  
  def test_report_handles_transactions_with_utc_timestamps
    Aggregation.expects(:aggregate).with(
      has_entry(:timestamp => Time.utc(2010, 5, 7, 18, 11, 25)))

    Transactor.report(@provider_key, 0 => {'user_key' => @user_key_one,
                                           'usage' => {'hits' => 1},
                                           'timestamp' => '2010-05-07 18:11:25'})
  end
  
  def test_report_handles_transactions_with_local_timestamps
    Aggregation.expects(:aggregate).with(
      has_entry(:timestamp => Time.utc(2010, 5, 7, 11, 11, 25)))

    Transactor.report(@provider_key, 0 => {'user_key' => @user_key_one,
                                           'usage' => {'hits' => 1},
                                           'timestamp' => '2010-05-07 18:11:25 +07:00'})
  end

  def test_report_archives
    time = Time.now

    Archiver.expects(:add).with(:service_id  => @service_id,
                                :contract_id => @contract_id_one,
                                :timestamp   => time,
                                :usage       => {@metric_id => 1})

    Archiver.expects(:add).with(:service_id  => @service_id,
                                :contract_id => @contract_id_two,
                                :timestamp   => time,
                                :usage       => {@metric_id => 1})

    Timecop.freeze(time) do
      Transactor.report(
        @provider_key,
        {'0' => {'user_key' => @user_key_one, 'usage' => {'hits' => 1}},
         '1' => {'user_key' => @user_key_two, 'usage' => {'hits' => 1}}})
    end
  end
  
  def test_report_raises_an_exception_when_provider_key_is_invalid
    assert_raise ProviderKeyInvalid do
      Transactor.report(
        'booo',
        {'0' => {'user_key' => @user_key_one, 'usage' => {'hits' => 1}}})
    end
  end
  
  def test_report_raises_an_exception_when_one_user_key_is_invalid
    begin
      Transactor.report(
        @provider_key,
        '0' => {'user_key' => 'invalid',     'usage' => {'hits' => 1}},
        '1' => {'user_key' => @user_key_two, 'usage' => {'hits' => 1}})

      flunk 'Expected MultipleErrors exception, but none raised'

    rescue MultipleErrors => exception
      assert_equal 1, exception.codes.size
      assert_equal 'user.invalid_key', exception.codes[0]
    end
  end
  
  def test_raises_an_exception_when_many_user_keys_are_invalid
    begin
      Transactor.report(
        @provider_key,
        '0' => {'user_key' => 'invalid', 'usage' => {'hits' => 1}},
        '1' => {'user_key' => 'invalid', 'usage' => {'hits' => 1}})

      flunk 'Expected MultipleErrors exception, but none raised'

    rescue MultipleErrors => exception
      assert_equal 2, exception.codes.size
      assert_equal 'user.invalid_key', exception.codes[0]
      assert_equal 'user.invalid_key', exception.codes[1]
    end
  end
  
  def test_raises_an_exception_when_the_contract_is_not_active
    contract = Contract.load(@service_id, @user_key_one)
    contract.state = :suspended
    contract.save

    begin
      Transactor.report(
        @provider_key,
        '0' => {'user_key' => @user_key_one, 'usage' => {'hits' => 1}},
        '1' => {'user_key' => @user_key_two, 'usage' => {'hits' => 1}})

      flunk 'Expected MultipleErrors exception, but none raised'

    rescue MultipleErrors => exception
      assert_equal 1, exception.codes.size
      assert_equal 'user.inactive_contract', exception.codes[0]
    end
  end
  
  def test_raises_an_exception_when_metric_names_in_one_transaction_are_invalid
    begin
      Transactor.report(
        @provider_key,
        '0' => {'user_key' => @user_key_one, 'usage' => {'hits' => 1}},
        '1' => {'user_key' => @user_key_two, 'usage' => {'monkeys' => 1}})

      flunk 'Expected MultipleErrors exception, but none raised'

    rescue MultipleErrors => exception
      assert_equal 1, exception.codes.size
      assert_equal 'provider.invalid_metric', exception.codes[1]
    end
  end
  
  def test_raises_an_exception_when_metric_names_in_many_transactions_of_different_contract_are_invalid
    begin
      Transactor.report(
        @provider_key,
        '0' => {'user_key' => @user_key_one, 'usage' => {'penguins' => 1}},
        '1' => {'user_key' => @user_key_two, 'usage' => {'monkeys' => 1}})

      flunk 'Expected MultipleErrors exception, but none raised'

    rescue MultipleErrors => exception
      assert_equal 2, exception.codes.size
      assert_equal 'provider.invalid_metric', exception.codes[0]
      assert_equal 'provider.invalid_metric', exception.codes[1]
    end
  end
  
  def test_raises_an_exception_when_metric_names_in_many_transactions_of_the_same_contract_are_invalid
    begin
      Transactor.report(
        @provider_key,
        '0' => {'user_key' => @user_key_one, 'usage' => {'penguins' => 1}},
        '1' => {'user_key' => @user_key_one, 'usage' => {'monkeys' => 1}})

      flunk 'Expected MultipleErrors exception, but none raised'

    rescue MultipleErrors => exception
      assert_equal 2, exception.codes.size
      assert_equal 'provider.invalid_metric', exception.codes[0]
      assert_equal 'provider.invalid_metric', exception.codes[1]
    end
  end
  
  def test_raises_an_exception_with_entries_for_invalid_transactions_only
    begin
      Transactor.report(
        @provider_key,
        '0' => {'user_key' => @user_key_one, 'usage' => {'hits' => 1}},
        '1' => {'user_key' => @user_key_one, 'usage' => {'monkeys' => 1}})

      flunk 'Expected MultipleErrors exception, but none raised'

    rescue MultipleErrors => exception
      assert_equal 1, exception.codes.size
      assert_equal 'provider.invalid_metric', exception.codes[1]
    end
  end
  
  def test_does_not_aggregate_anything_when_at_least_one_transaction_is_invalid
    Aggregation.expects(:aggregate).never

    begin
      Transactor.report(
        @provider_key,
        '0' => {'user_key' => 'invalid',     'usage' => {'hits' => 1}},
        '1' => {'user_key' => @user_key_two, 'usage' => {'hits' => 1}})
    rescue MultipleErrors
    end
  end









  # test 'reports transactions even when they exceed limits' do
  #   4.times do
  #     Transaction.report!(:cinstance => @cinstance_one,
  #                         :usage => {'hits' => 1})
  #   end

  #   @plan.usage_limits.create!(:metric => @metric, :value => 4, :period => :month)

  #   assert_change_in_usage :cinstance => @cinstance_one, :by => 2 do
  #     Transaction.report_multiple!(
  #       @provider_account.id,
  #       '0' => {:user_key => @user_key_one, :usage => {'hits' => 1}},
  #       '1' => {:user_key => @user_key_one, :usage => {'hits' => 1}})
  #   end
  # end

  # context 'with pricing rules' do
  #   setup do
  #     set_billing_mode(@provider_account, :prepaid)

  #     @plan.pricing_rules.create!(:metric => @metric, :cost_per_unit => 0.1)
  #     @buyer_account_one.update_attribute(:buyerbalance, 100)
  #     @buyer_account_two.update_attribute(:buyerbalance, 100)
  #   end

  #   should 'update balances of provider and buyers' do
  #     assert_difference '@buyer_account_one.buyerbalance', -0.2 do
  #       assert_difference '@buyer_account_two.buyerbalance', -0.1 do
  #         assert_difference '@provider_account.providerbalance', 0.3 do
  #           Transaction.report_multiple!(
  #             @provider_account.id,
  #             '0' => {:user_key => @user_key_one, :usage => {'hits' => 1}},
  #             '1' => {:user_key => @user_key_one, :usage => {'hits' => 1}},
  #             '2' => {:user_key => @user_key_two, :usage => {'hits' => 1}})

  #           @provider_account.reload
  #           @buyer_account_one.reload
  #           @buyer_account_two.reload
  #         end
  #       end
  #     end
  #   end

  #   should 'pay the cost asynchronously' do
  #     Worker.expects(:asynch_pay).
  #       with(:cinstance_id => @cinstance_one.id,
  #            :cost => NumericHash.new(@metric.id => 0.2),
  #            :usage => NumericHash.new(@metric.id => 2))

  #     Transaction.report_multiple!(
  #       @provider_account.id,
  #       '0' => {:user_key => @user_key_one, :usage => {'hits' => 1}},
  #       '1' => {:user_key => @user_key_one, :usage => {'hits' => 1}})
  #   end
  # end



end