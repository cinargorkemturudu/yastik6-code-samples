import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/crypto_service.dart';

abstract class CloudBackupStrategy {
  Future<bool> backupDatabase(File backupFile);
  /// Downloads the backup to [destinationPath]; never writes to the live database.
  Future<void> downloadBackup(String destinationPath);
  Future<GoogleSignInAccount?> signIn();
  Future<void> signOut();
}

/// The parts of the local database that backup/restore needs; [LocalDatabase] in the app, a fake in tests.
abstract class BackupDatabaseFile {
  Future<String> get path;
  Future<void> checkpoint();
  Future<void> close();
}

/// The downloaded file decrypted fine but is not a SQLite database.
class InvalidBackupContentException implements Exception {
  const InvalidBackupContentException();
}

class CloudBackupService {
  static final List<int> _sqliteHeader = 'SQLite format 3\u0000'.codeUnits;

  final CloudBackupStrategy _strategy;
  final CryptoService _cryptoService;
  final BackupDatabaseFile _database;

  CloudBackupService({
    required CryptoService crypto,
    required BackupDatabaseFile database,
    required CloudBackupStrategy strategy,
  }) : _cryptoService = crypto,
       _database = database,
       _strategy = strategy;

  Future<bool> backupDatabase(String passphrase) async {
    final dbPath = await _database.path;
    final dbFile = File(dbPath);

    if (!await dbFile.exists()) {
      throw Exception(
        "Yerel veritabanı bulunamadı. Lütfen önce uygulamaya bir işlem ekleyin.",
      );
    }

    // 1. Make sure the file on disk holds every committed write, then read and encrypt it
    await _database.checkpoint();
    final rawBytes = await dbFile.readAsBytes();
    final encryptedPayload = await _cryptoService.encryptBackup(
      rawBytes,
      passphrase,
    );

    // 2. Upload the encrypted copy from a temp file, and always clean it up
    final tempEncryptedFile = File('$dbPath.enc');
    try {
      await tempEncryptedFile.writeAsBytes(encryptedPayload, flush: true);
      return await _strategy.backupDatabase(tempEncryptedFile);
    } finally {
      if (await tempEncryptedFile.exists()) await tempEncryptedFile.delete();
    }
  }

  /// Replaces the local database with the cloud backup. Everything that can fail (download,
  /// wrong passphrase, corrupted file) happens before the live database is touched, so a
  /// failed restore leaves the current portfolio exactly as it was.
  Future<void> restoreDatabase(String passphrase) async {
    final dbPath = await _database.path;
    final downloaded = File('$dbPath.download');
    final restored = File('$dbPath.restore');

    try {
      await _strategy.downloadBackup(downloaded.path);
      final plain = await _cryptoService.decryptBackup(
        await downloaded.readAsBytes(),
        passphrase,
      );
      if (!_isSqliteFile(plain)) throw const InvalidBackupContentException();
      await restored.writeAsBytes(plain, flush: true);

      // Only now swap it in: close the connection, replace the file, drop the old journal files
      await _database.close();
      await restored.rename(dbPath);
      for (final suffix in const ['-wal', '-shm', '-journal']) {
        final sidecar = File('$dbPath$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }
    } finally {
      for (final temp in [downloaded, restored]) {
        if (await temp.exists()) await temp.delete();
      }
    }
  }

  bool _isSqliteFile(List<int> bytes) {
    if (bytes.length < _sqliteHeader.length) return false;
    for (var i = 0; i < _sqliteHeader.length; i++) {
      if (bytes[i] != _sqliteHeader[i]) return false;
    }
    return true;
  }

  Future<GoogleSignInAccount?> signIn() => _strategy.signIn();
  Future<void> signOut() => _strategy.signOut();
}
