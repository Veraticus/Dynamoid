require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

describe "Dynamoid::Document" do

  it 'initializes a new document' do
    @address = Address.new
    
    @address.new_record.should be_true
    @address.attributes.should == {:id=>nil, :created_at=>nil, :updated_at=>nil, :city=>nil, :options=>nil}
  end

  it 'responds to will_change! methods for all fields' do
    @address = Address.new
    @address.should respond_to(:id_will_change!)
    @address.should respond_to(:options_will_change!)
    @address.should respond_to(:created_at_will_change!)
    @address.should respond_to(:updated_at_will_change!)
  end
  
  it 'initializes a new document with attributes' do
    @address = Address.new(:city => 'Chicago')
    
    @address.new_record.should be_true
    
    @address.attributes.should == {:id=>nil, :created_at=>nil, :updated_at=>nil, :city=>"Chicago", :options=>nil}
  end

  it 'initializes a new document with a virtual attribute' do
    @address = Address.new(:zip_code => '12345')
    
    @address.new_record.should be_true
    
    @address.attributes.should == {:id=>nil, :created_at=>nil, :updated_at=>nil, :city=>"Chicago", :options=>nil}
  end

  it 'allows interception of write_attribute on load' do
    class Model
      include Dynamoid::Document
      field :city
      def city=(value); self[:city] = value.downcase; end
    end
    Model.new(:city => "Chicago").city.should == "chicago"
  end
  
  it 'creates a new document' do
    @address = Address.create(:city => 'Chicago')
    
    @address.new_record.should be_false
    @address.id.should_not be_nil
  end

  it 'knows if a document exists or not' do
    @address = Address.create(:city => 'Chicago')
    Address.exists?(@address.id).should be_true
    Address.exists?("does-not-exist").should be_false
  end
  
  it 'tests equivalency with itself' do
    @address = Address.create(:city => 'Chicago')
    
    @address.should == @address
  end

  it 'is not equivalent to another document' do
    @address.should_not == Address.create
  end
  
  it 'is not equivalent to another object' do
    @address = Address.create(:city => 'Chicago')
    @address.should_not == "test"
  end
  
  it "isn't equal to nil" do
    @address = Address.create(:city => 'Chicago')
    @address.should_not == nil
  end
  
  it 'gets errors courtesy of ActiveModel' do
    @address = Address.create(:city => 'Chicago')
    
    @address.errors.should be_empty
    @address.errors.full_messages.should be_empty
  end
  
  it 'reloads itself and sees persisted changes' do
    @address = Address.create
    
    Address.first.update_attributes(:city => 'Chicago')
    
    @address.reload.city.should == 'Chicago'
  end

  it 'reloads document with range key' do
    tweet = Tweet.create(:tweet_id => 'x', :group => 'abc')
    tweet.reload.group.should == 'abc'
  end
  
  it 'has default table options' do
    @address = Address.create
    
    @address.id.should_not be_nil
    Address.table_name.should == 'dynamoid_tests_addresses'
    Address.hash_key.should == :id
    Address.read_capacity.should == 100
    Address.write_capacity.should == 20
  end
  
  it 'follows any table options provided to it' do
    @tweet = Tweet.create(:group => 12345)
    
    lambda {@tweet.id}.should raise_error(NoMethodError)
    @tweet.tweet_id.should_not be_nil
    Tweet.table_name.should == 'dynamoid_tests_twitters'
    Tweet.hash_key.should == :tweet_id
    Tweet.read_capacity.should == 200
    Tweet.write_capacity.should == 200
  end
end
