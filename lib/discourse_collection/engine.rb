# frozen_string_literal: true

module ::DiscourseCollection
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseCollection
    config.autoload_paths << File.join(config.root, "lib")
    # Settings in config/settings.yml reference validators by top-level constant
    # (CollectionName{Min,Max}LengthValidator). Under the plain `lib` root Zeitwerk
    # would map lib/validators/*.rb to Validators::*, so give lib/validators its own
    # top-level autoload root — same reason core appends root/lib/validators in
    # config/application.rb. SiteSettings::YamlLoader runs early in boot and
    # constantizes these during load_setting; without this the constant is not
    # loadable yet and boot aborts with a NameError.
    config.autoload_paths << File.join(config.root, "lib", "validators")
  end
end
