class Team
  include Dynamoid::Document

  field :captain
  field :players, :serialized

  optimistic_lock_field :commit_version
end
