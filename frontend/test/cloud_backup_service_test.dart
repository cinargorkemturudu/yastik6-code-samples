import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:yastik_alti/core/crypto_service.dart';
import 'package:yastik_alti/domain/services/cloud_backup_service.dart';

/// Stands in for Google Drive / iCloud: keeps the last uploaded file in memory.
class _FakeCloud implements CloudBackupStrategy {
  Uint8List? stored;

  @override
  Future<bool> backupDatabase(File backupFile) async {
    stored = await backupFile.readAsBytes();
    return true;
  }

  @override
  Future<void> downloadBackup(String destinationPath) async {
    final bytes = stored;
    if (bytes == null) throw Exception('No backup in the cloud');
    await File(destinationPath).writeAsBytes(bytes);
  }

  @override
  Future<GoogleSignInAccount?> signIn() async => null;

  @override
  Future<void> signOut() async {}
}

/// A phone: a database file in its own temp directory.
class _FakePhone implements BackupDatabaseFile {
  final Directory dir;
  int closeCount = 0;
  int checkpointCount = 0;

  _FakePhone(this.dir);

  @override
  Future<String> get path async => '${dir.path}/yastik6.db';

  @override
  Future<void> checkpoint() async => checkpointCount++;

  @override
  Future<void> close() async => closeCount++;

  Future<void> write(String rows) =>
      File('${dir.path}/yastik6.db').writeAsBytes(sqlite(rows));
  Future<List<int>> read() => File('${dir.path}/yastik6.db').readAsBytes();
  List<String> files() =>
      dir.listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
}

List<int> sqlite(String rows) => utf8.encode('SQLite format 3\u0000$rows');

void main() {
  final crypto = CryptoService(iterations: 1000);
  late _FakeCloud cloud;
  late _FakePhone oldPhone;
  late _FakePhone newPhone;

  setUp(() {
    cloud = _FakeCloud();
    oldPhone = _FakePhone(Directory.systemTemp.createTempSync('old_phone'));
    newPhone = _FakePhone(Directory.systemTemp.createTempSync('new_phone'));
  });

  tearDown(() {
    oldPhone.dir.deleteSync(recursive: true);
    newPhone.dir.deleteSync(recursive: true);
  });

  CloudBackupService serviceOn(_FakePhone phone) =>
      CloudBackupService(crypto: crypto, database: phone, strategy: cloud);

  test(
    'backup uploads an encrypted copy, checkpoints first, and leaves no temp file',
    () async {
      await oldPhone.write('gold 8g');

      expect(await serviceOn(oldPhone).backupDatabase('correct horse'), isTrue);

      expect(oldPhone.checkpointCount, 1);
      expect(
        utf8.decode(cloud.stored!, allowMalformed: true),
        isNot(contains('gold 8g')),
      );
      expect(oldPhone.files(), ['yastik6.db']);
    },
  );

  test('a backup restores on a new phone with the same passphrase', () async {
    await oldPhone.write('gold 8g');
    await serviceOn(oldPhone).backupDatabase('correct horse');
    await newPhone.write('empty');
    await File(
      '${newPhone.dir.path}/yastik6.db-wal',
    ).writeAsString('stale wal');

    await serviceOn(newPhone).restoreDatabase('correct horse');

    expect(await newPhone.read(), sqlite('gold 8g'));
    expect(newPhone.closeCount, 1);
    expect(newPhone.files(), [
      'yastik6.db',
    ], reason: 'temp files and the old WAL are removed');
  });

  test('a wrong passphrase leaves the current portfolio untouched', () async {
    await oldPhone.write('gold 8g');
    await serviceOn(oldPhone).backupDatabase('correct horse');
    await newPhone.write('usd 20');

    await expectLater(
      serviceOn(newPhone).restoreDatabase('wrong horse'),
      throwsA(isA<BackupDecryptionException>()),
    );

    expect(await newPhone.read(), sqlite('usd 20'));
    expect(newPhone.closeCount, 0);
    expect(newPhone.files(), ['yastik6.db']);
  });

  test('a corrupted download leaves the current portfolio untouched', () async {
    await oldPhone.write('gold 8g');
    await serviceOn(oldPhone).backupDatabase('correct horse');
    cloud.stored![cloud.stored!.length - 1] ^= 0x01;
    await newPhone.write('usd 20');

    await expectLater(
      serviceOn(newPhone).restoreDatabase('correct horse'),
      throwsA(isA<BackupDecryptionException>()),
    );

    expect(await newPhone.read(), sqlite('usd 20'));
    expect(newPhone.files(), ['yastik6.db']);
  });

  test(
    'a backup that decrypts to something other than a SQLite file is rejected',
    () async {
      cloud.stored = await crypto.encryptBackup(
        utf8.encode('not a database'),
        'correct horse',
      );
      await newPhone.write('usd 20');

      await expectLater(
        serviceOn(newPhone).restoreDatabase('correct horse'),
        throwsA(isA<InvalidBackupContentException>()),
      );

      expect(await newPhone.read(), sqlite('usd 20'));
      expect(newPhone.closeCount, 0);
    },
  );

  test('a failed download leaves the current portfolio untouched', () async {
    await newPhone.write('usd 20');

    await expectLater(
      serviceOn(newPhone).restoreDatabase('correct horse'),
      throwsException,
    );

    expect(await newPhone.read(), sqlite('usd 20'));
    expect(newPhone.files(), ['yastik6.db']);
  });
}
