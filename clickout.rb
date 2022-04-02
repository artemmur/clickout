require 'fluent/plugin/output'
require 'fluent/config/error'
require 'net/http'
require 'date'
require 'json'

module Fluent
  module Plugin
    class ClickOut < Fluent::Plugin::Output
        Fluent::Plugin.register_output("clickout", self)
        
        class RetryableResponse < StandardError; end

        helpers :compat_parameters

        DEFAULT_TIMEKEY = 60 * 60 * 24

        desc "IP or fqdn of ClickHouse node"
        config_param :host, :string
        desc "Port of ClickHouse HTTP interface"
        config_param :port, :integer, default: 8123
        desc "Database to use"
        config_param :database, :string, default: "default"
        desc "Table to use"
        config_param :table, :string
        desc "User of Clickhouse database"
        config_param :user, :string, default: "default"
        desc "Password of Clickhouse database"
        config_param :password, :string, default: ""
        desc "Offset in minutes, could be useful to substract timestamps because of timezones"
        config_param :tz_offset, :integer, default: 0
        desc "Name of internal fluentd time field (if need to use)"
        config_param :datetime_name, :string, default: nil
        desc "Raise UnrecoverableError when the response is non success, 4xx/5xx"
        config_param :error_response_as_unrecoverable, :bool, default: false
        desc "The list of retryable response code"
        config_param :retryable_response_codes, :array, value_type: :integer, default: [503]
        config_section :buffer do
            config_set_default :@type, "file"
            config_set_default :chunk_keys, ["time"]
            config_set_default :flush_at_shutdown, true
            config_set_default :timekey, DEFAULT_TIMEKEY
        end

        def configure(conf)
            super
            @uri, @uri_params = make_uri(conf)
            @table            = conf["table"]
            @tz_offset        = conf["tz_offset"].to_i
            @datetime_name    = conf["datetime_name"]

            test_connection(conf)
        end

        def multi_workers_ready?
            true
        end

        def test_connection(conf)
            uri = @uri.clone
            uri.query = URI.encode_www_form(@uri_params.merge({"query" => "SHOW TABLES"}))
            begin
        	    res = Net::HTTP.get_response(uri)
            rescue Errno::ECONNREFUSED
        	    raise Fluent::ConfigError, "Couldn't connect to ClickHouse at #{ @uri } - connection refused"
            end
            if res.code != "200"
                raise Fluent::ConfigError, "ClickHouse server responded non-200 code: #{ res.body }"
            end
        end

        def make_uri(conf)
            uri = URI("http://#{ conf["host"] }:#{ conf["port"] || 8123 }/")
            params = {
                "database" => conf["database"] || "default",
                "user"     => conf["user"] || "default",
                "password" => conf["password"] || "",
                "input_format_skip_unknown_fields" => 1
            }
            return uri, params
        end

        def format(tag, timestamp, record)
            if @datetime_name
                record[@datetime_name] = timestamp + @tz_offset * 60
            end

            return json.dump(record) + "\n"
	    end

        def write(chunk)
          uri = @uri.clone
          query = {"query" => "INSERT INTO #{@table} FORMAT JSONEachRow"}
          uri.query = URI.encode_www_form(@uri_params.merge(query))

          req = Net::HTTP::Post.new(uri)
          req.body = chunk.read

          res = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }

          if res.is_a?(Net::HTTPSuccess)
            return
          end
          
          msg = "Clickhouse responded: #{res.body}"

          if @retryable_response_codes.include?(res.code.to_i)
            raise RetryableResponse, msg
          end

          if @error_response_as_unrecoverable
            raise Fluent::UnrecoverableError, msg
          else
            log.error msg
          end
        end
    end
  end
end