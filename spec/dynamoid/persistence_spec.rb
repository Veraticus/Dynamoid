require File.expand_path(File.dirname(__FILE__) + '/../spec_helper')

describe "Dynamoid::Persistence" do

  before do
    Random.stubs(:rand).with(Dynamoid::Config.partition_size).returns(0)
    @address = Address.new
  end

  context 'without AWS keys' do
    unless ENV['ACCESS_KEY'] && ENV['SECRET_KEY']
      before do
        Dynamoid::Adapter.delete_table(Address.table_name) if Dynamoid::Adapter.list_tables.include?(Address.table_name)
      end

      it 'creates a table' do
        Address.create_table(:table_name => Address.table_name)

        Dynamoid::Adapter.list_tables.should include 'dynamoid_tests_addresses'
      end

      it 'checks if a table already exists' do
        Address.create_table(:table_name => Address.table_name)

        Address.table_exists?(Address.table_name).should be_true
        Address.table_exists?('crazytable').should be_false
      end
    end
  end

  describe "#undump_field" do
    context "datetime fields" do
      let(:now_t) { Time.now }
      let(:now_d) { Date.today }
      let(:now_dt) { now_t.to_datetime }
      let(:now_f) { now_t.to_f }
      let(:field) { {type: :datetime} }

      it "just returns a Time object" do 
        Address.undump_field(now_t, field).should eq(now_t)
      end

      it "just returns a Date object" do
        Address.undump_field(now_d, field).should eq(now_d)
      end

      it "just returns a DateTime object" do
        Address.undump_field(now_dt, field).should eq(now_dt)
      end

      context "with no time zones" do
        it "returns the right time from the float argument" do
          time = Address.undump_field(now_f, field)
          
          time.to_time.to_f.should eq(now_f)
          time.zone.should eq(now_dt.zone)
        end
      end

      context "with time zones" do
        it "returns a time from the argument when no time zone" do
          Time.stubs(zone: nil)
          Address.undump_field(now_f, field).to_time.to_f.should eq(now_f)
        end

        it "returns a time from the argument and zone" do
          zone = stub
          date = DateTime.new(now_t.year, now_t.month, now_t.day, now_t.hour, now_t.min, now_t.sec, 0)
          zone.expects(:at).with(now_f).returns(
            stub(
              to_datetime: date
            )
          )
          Time.stubs(zone: zone)

          Address.undump_field(now_f, field).should eq(date)
        end
      end
    end
  end

  it 'assigns itself an id on save' do
    @address.save

    Dynamoid::Adapter.read("dynamoid_tests_addresses", @address.id)[:id].should == @address.id
  end

  it 'assigns itself an id on save only if it does not have one' do
    @address.id = 'test123'
    @address.save

    Dynamoid::Adapter.read("dynamoid_tests_addresses", 'test123').should_not be_empty
  end

  it 'has a table name' do
    Address.table_name.should == 'dynamoid_tests_addresses'
  end

  it 'saves indexes along with itself' do
    @user = User.new(:name => 'Josh')

    @user.expects(:save_indexes).once.returns(true)
    @user.save
  end

  it 'deletes an item completely' do
    @user = User.create(:name => 'Josh')
    @user.destroy

    Dynamoid::Adapter.read("dynamoid_tests_users", @user.id).should be_nil
  end

  it 'keeps string attributes as strings' do
    @user = User.new(:name => 'Josh')
    @user.send(:dump)[:name].should == 'Josh'
  end

  it 'dumps datetime attributes' do
    @user = User.create(:name => 'Josh')
    @user.send(:dump)[:name].should == 'Josh'
  end

  it 'dumps integer attributes' do
    @subscription = Subscription.create(:length => 10)
    @subscription.send(:dump)[:length].should == 10
  end

  it 'dumps set attributes' do
    @subscription = Subscription.create(:length => 10)
    @magazine = @subscription.magazine.create

    @subscription.send(:dump)[:magazine_ids].should == Set[@magazine.id]
  end

  it 'handles nil attributes properly' do
    Address.undump(nil).should be_a(Hash)
  end

  it 'dumps and undump a serialized field' do
    @address.options = (hash = {:x => [1, 2], "foobar" => 3.14})
    Address.undump(@address.send(:dump))[:options].should == hash
  end

  it 'loads a hash into a serialized field' do
    hash = {foo: :bar}
    Address.new(options: hash).options.should == hash
  end

  it 'loads attributes from a hash' do
    @time = DateTime.now
    @hash = {:name => 'Josh', :created_at => @time.to_f}

    User.undump(@hash)[:name].should == 'Josh'
    User.undump(@hash)[:created_at].to_f == @time.to_f
  end

  it 'runs the before_create callback only once' do
    CamelCase.any_instance.expects(:doing_before_create).once.returns(true)

    CamelCase.create
  end

  it 'runs after save callbacks when doing #create' do
    CamelCase.any_instance.expects(:doing_after_create).once.returns(true)

    CamelCase.create
  end

  it 'runs after save callbacks when doing #save' do
    CamelCase.any_instance.expects(:doing_after_create).once.returns(true)

    CamelCase.new.save
  end

  it 'works with a HashWithIndifferentAccess' do
    hash = ActiveSupport::HashWithIndifferentAccess.new("city" => "Atlanta")

    lambda {Address.create(hash)}.should_not raise_error
  end

  context 'update' do

    before :each do
      @tweet = Tweet.create(:tweet_id => 1, :group => 'abc', :count => 5, :tags => ['db', 'sql'], :user_name => 'john')
    end

    it 'support add/delete operation on a field' do
      @tweet.update do |t|
        t.add(:count => 3)
        t.delete(:tags => ['db'])
      end

      @tweet.count.should eq(8)
      @tweet.tags.to_a.should eq(['sql'])
    end

    it 'checks the conditions on update' do
      @tweet.update(:if => { :count => 5 }) do |t|
        t.add(:count => 3)
      end.should be_true

      @tweet.count.should eq(8)

      @tweet.update(:if => { :count => 5 }) do |t|
        t.add(:count => 3)
      end.should be_false

      @tweet.count.should eq(8)

      expect {
        @tweet.update!(:if => { :count => 5 }) do |t|
          t.add(:count => 3)
        end
      }.to raise_error(Dynamoid::Errors::ConditionalCheckFailedException)
    end

  end

  context 'delete' do
    it 'deletes model with datetime range key' do
      lambda {
        msg = Message.create!(:message_id => 1, :time => DateTime.now, :text => "Hell yeah")
        msg.destroy
      }.should_not raise_error
    end
  end
end
