import 'dart:io';

import 'package:dbus/dbus.dart';

/// An explicit user action reveals an already generated local folder. No
/// document-defined URL, shell command or remote URI reaches this service.
class LocalOutputService {
  Future<void> reveal(String directory) async {
    final uri = Directory(directory).absolute.uri;
    final client = DBusClient.session();
    try {
      await client.callMethod(
        destination: 'org.freedesktop.FileManager1',
        path: DBusObjectPath('/org/freedesktop/FileManager1'),
        interface: 'org.freedesktop.FileManager1',
        name: 'ShowFolders',
        values: [
          DBusArray.string([uri.toString()]),
          const DBusString(''),
        ],
        replySignature: DBusSignature(''),
      );
    } finally {
      await client.close();
    }
  }
}
