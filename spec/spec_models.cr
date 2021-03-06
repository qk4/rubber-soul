require "rethinkdb-orm"
require "time"

abstract class AbstractBase < RethinkORM::Base
end

class RayGun < AbstractBase
  attribute laser_colour : String = "red"
  attribute barrel_length : Float32 = 23.42
  attribute rounds : Int32 = 32
  attribute ip : String = "127.0.0.1", es_type: "ip"
  attribute last_shot : Time = ->{ Time.utc }
end

class Programmer < AbstractBase
  attribute name : String
end

class Broke < AbstractBase
  attribute breaks : String
  attribute status : Bool
  attribute hasho : Hash(String, String)
end

class Beverage::Coffee < AbstractBase
  attribute temperature : Int32 = 54
  attribute created_at : Time = ->{ Time.utc }

  belongs_to Programmer, dependent: :destroy
end

class Migraine < AbstractBase
  table :ouch
  attribute duration : Time = ->{ Time.utc + 50.years }

  belongs_to Programmer
end

RubberSoul::MANAGED_TABLES = [RayGun, Programmer, Broke, Beverage::Coffee, Migraine]
