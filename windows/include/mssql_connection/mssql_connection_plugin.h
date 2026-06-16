#ifndef FLUTTER_PLUGIN_MSSQL_CONNECTION_PLUGIN_H_
#define FLUTTER_PLUGIN_MSSQL_CONNECTION_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

namespace mssql_connection {

class MssqlConnectionPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  MssqlConnectionPlugin();

  virtual ~MssqlConnectionPlugin();

  // Disallow copy and assign.
  MssqlConnectionPlugin(const MssqlConnectionPlugin&) = delete;
  MssqlConnectionPlugin& operator=(const MssqlConnectionPlugin&) = delete;
};

}  // namespace mssql_connection

#endif  // FLUTTER_PLUGIN_MSSQL_CONNECTION_PLUGIN_H_
