import 'package:dbus/dbus.dart';

/// Opens one explicitly user-authorized HTTP(S) URI through the desktop portal.
/// Contract renderers and parser workers never receive this capability.
class ExternalUriService {
  Future<void> open(Uri uri) async {
    if (!uri.isAbsolute ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(
        uri,
        'uri',
        'Expected an HTTP(S) URI without credentials',
      );
    }
    final client = DBusClient.session();
    try {
      await client.callMethod(
        destination: 'org.freedesktop.portal.Desktop',
        path: DBusObjectPath('/org/freedesktop/portal/desktop'),
        interface: 'org.freedesktop.portal.OpenURI',
        name: 'OpenURI',
        values: [
          const DBusString(''),
          DBusString(uri.toString()),
          DBusDict.stringVariant(const {}),
        ],
        replySignature: DBusSignature('o'),
      );
    } finally {
      await client.close();
    }
  }
}
