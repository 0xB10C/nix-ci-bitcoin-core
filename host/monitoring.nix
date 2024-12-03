{ pkgs, config, ... }:

{
  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = 1234;
        protocol = "http";
      };
      analytics.reporting_enabled = false;
    };
    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          url = "http://127.0.0.1:${toString config.services.prometheus.port}";
        }
        {
          name = "Loki";
          type = "loki";
          url = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}";
        }
      ];
    };
  };

  services.prometheus = {
    enable = true;
    port = 9001;

    scrapeConfigs = [
      {
        job_name = "host-node";
        static_configs = [
          { targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ]; }
        ];
      }
    ];

    exporters = {
      node = {
        enable = true;
        enabledCollectors = [ "systemd" ];
        port = 9002;
      };
    };
  };

  services.loki = {
    enable = true;
    configuration = {
      # Basic stuff
      auth_enabled = false;
      server = {
        http_listen_port = 3100;
        log_level = "warn";
      };
      common = {
        path_prefix = config.services.loki.dataDir;
        storage.filesystem = {
          chunks_directory = "${config.services.loki.dataDir}/chunks";
          rules_directory = "${config.services.loki.dataDir}/rules";
        };
        replication_factor = 1;
        ring.kvstore.store = "inmemory";
        ring.instance_addr = "127.0.0.1";
      };

      ingester.chunk_encoding = "snappy";

      limits_config = {
        retention_period = "120h";
        ingestion_burst_size_mb = 16;
        reject_old_samples = true;
        reject_old_samples_max_age = "12h";
      };

      table_manager = {
        retention_deletes_enabled = true;
        retention_period = "120h";
      };

      compactor = {
        retention_enabled = true;
        compaction_interval = "10m";
        working_directory = "${config.services.loki.dataDir}/compactor";
        delete_request_cancel_period = "10m"; # don't wait 24h before processing the delete_request
        retention_delete_delay = "2h";
        retention_delete_worker_count = 150;
        delete_request_store = "filesystem";
      };

      schema_config.configs = [
        {
          from = "2024-11-29";
          store = "tsdb";
          object_store = "filesystem";
          schema = "v13";
          index.prefix = "index_";
          index.period = "24h";
        }
      ];

      query_range.cache_results = true;
      limits_config.split_queries_by_interval = "24h";
    };
  };

  services.promtail = {
    enable = true;
    configuration = {
      server = {
        http_listen_port = 3031;
        grpc_listen_port = 0;
      };
      positions = {
        filename = "/tmp/positions.yaml";
      };
      clients = [
        {
          url = "http://127.0.0.1:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
        }
      ];
      scrape_configs = [
        {
          job_name = "journal";
          journal = {
            max_age = "12h";
            labels = {
              job = "systemd-journal";
              host = config.networking.hostName;
            };
          };
          relabel_configs = [
            {
              source_labels = [ "__journal__systemd_unit" ];
              target_label = "unit";
            }
          ];
        }
      ];
    };
  };

}
