class CamelCase
  include Dynamoid::Document

  field :color

  belongs_to :magazine
  has_many :users
  has_one :sponsor
  has_and_belongs_to_many :subscriptions

  before_create :doing_before_create
  after_create :doing_after_create
  before_update :doing_before_update
  after_update :doing_after_update
  before_save :doing_before_save
  after_save :doing_after_save

  private

  def doing_before_create
    true
  end

  def doing_after_create
    true
  end

  def doing_before_update
    true
  end

  def doing_after_update
    true
  end

  def doing_before_save
    true
  end

  def doing_after_save
    true
  end

end
