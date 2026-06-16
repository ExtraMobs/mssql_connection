#include "include/mssql_connection/mssql_connection_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace mssql_connection {

// static
void MssqlConnectionPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "mssql_connection",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<MssqlConnectionPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        result->NotImplemented();
      });

  registrar->AddPlugin(std::move(plugin));
}

MssqlConnectionPlugin::MssqlConnectionPlugin() {}

MssqlConnectionPlugin::~MssqlConnectionPlugin() {}

}  // namespace mssql_connection
