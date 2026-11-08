import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:icloud_storage/icloud_storage.dart';
import 'package:yastik_alti/data/local/db_constants.dart';

import '../../core/env.dart';
import '../../domain/services/cloud_backup_service.dart';

class GoogleDriveBackupStrategy implements CloudBackupStrategy {
  static const _scopes = [drive.DriveApi.driveAppdataScope];

  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  bool _isInitialized = false;

  Future<void> _ensureInitialized() async {
    if (!_isInitialized) {
      await _googleSignIn.initialize(serverClientId: Env.googleDriveClientId);
      _isInitialized = true;
    }
  }

  Future<http.Client?> _getAuthenticatedClient(
    GoogleSignInAccount account,
  ) async {
    try {
      var authorization = await account.authorizationClient
          .authorizationForScopes(_scopes);
      authorization ??= await account.authorizationClient.authorizeScopes(
        _scopes,
      );
      return authorization.authClient(scopes: _scopes);
    } catch (e) {
      throw Exception("Yetkilendirme Hatası: $e");
    }
  }

  @override
  Future<bool> backupDatabase(File backupFile) async {
    final account = await signIn();
    if (account == null) {
      throw Exception("Google Girişi başarısız oldu.");
    }

    final client = await _getAuthenticatedClient(account);
    if (client == null) {
      throw Exception("Google Drive API yetkisi alınamadı.");
    }

    try {
      final driveApi = drive.DriveApi(client);
      // Upload the file passed in as a parameter
      final media = drive.Media(backupFile.openRead(), backupFile.lengthSync());
      final cloudFileName = 'yastik6_backup_${DbConstants.dbName}';

      final driveFile = drive.File()
        ..name = cloudFileName
        ..parents = ['appDataFolder'];

      final fileList = await driveApi.files.list(
        spaces: 'appDataFolder',
        q: "name = '$cloudFileName'",
      );

      if (fileList.files != null && fileList.files!.isNotEmpty) {
        final oldFileId = fileList.files!.first.id;
        if (oldFileId != null) {
          await driveApi.files.delete(oldFileId);
        }
      }

      await driveApi.files.create(driveFile, uploadMedia: media);
      debugPrint("Google Drive Yedekleme Başarılı!");
      return true;
    } catch (e) {
      throw Exception("Drive Yükleme Hatası: $e");
    }
  }

  @override
  Future<void> downloadBackup(String destinationPath) async {
    final account = await signIn();
    if (account == null) throw Exception("Google Girişi başarısız oldu.");

    final client = await _getAuthenticatedClient(account);
    if (client == null) throw Exception("Google Drive API yetkisi alınamadı.");

    try {
      final driveApi = drive.DriveApi(client);
      final cloudFileName = 'yastik6_backup_${DbConstants.dbName}';

      final fileList = await driveApi.files.list(
        spaces: 'appDataFolder',
        q: "name = '$cloudFileName'",
      );

      if (fileList.files == null || fileList.files!.isEmpty) {
        throw Exception(
          "Bulutta '$cloudFileName' adlı yedek dosyası bulunamadı.",
        );
      }

      final fileId = fileList.files!.first.id;
      if (fileId == null) throw Exception("Dosya ID'si alınamadı.");

      final drive.Media media =
          await driveApi.files.get(
                fileId,
                downloadOptions: drive.DownloadOptions.fullMedia,
              )
              as drive.Media;

      final List<int> dataStore = [];
      await for (final data in media.stream) {
        dataStore.addAll(data);
      }
      await File(destinationPath).writeAsBytes(dataStore, flush: true);

      debugPrint("Google Drive yedeği indirildi.");
    } catch (e) {
      throw Exception("Drive İndirme Hatası: $e");
    }
  }

  @override
  Future<GoogleSignInAccount?> signIn() async {
    try {
      await _ensureInitialized();
      return await _googleSignIn.authenticate();
    } catch (error) {
      throw Exception("Giriş Hatası: $error");
    }
  }

  @override
  Future<void> signOut() async {
    await _ensureInitialized();
    await _googleSignIn.signOut();
  }
}

class ICloudBackupStrategy implements CloudBackupStrategy {
  final String _containerId = 'iCloud.com.yourdomain.yastikAlti';

  @override
  Future<bool> backupDatabase(File backupFile) async {
    try {
      final cloudFileName = 'yastik6_backup_${DbConstants.dbName}';

      await ICloudStorage.upload(
        containerId: _containerId,
        filePath: backupFile.path, // Parametre gelen dosya
        destinationRelativePath: cloudFileName,
        onProgress: (stream) {
          stream.listen(
            (progress) => debugPrint('iCloud Yükleniyor: %$progress'),
          );
        },
      );

      debugPrint("iCloud Yedekleme Başarılı!");
      return true;
    } catch (e) {
      throw Exception("iCloud Yükleme Hatası: $e");
    }
  }

  @override
  Future<void> downloadBackup(String destinationPath) async {
    try {
      final cloudFileName = 'yastik6_backup_${DbConstants.dbName}';

      await ICloudStorage.download(
        containerId: _containerId,
        relativePath: cloudFileName,
        destinationFilePath: destinationPath,
        onProgress: (stream) {
          stream.listen(
            (progress) => debugPrint('iCloud İndiriliyor: %$progress'),
          );
        },
      );

      debugPrint("iCloud yedeği indirildi.");
    } catch (e) {
      throw Exception("iCloud İndirme Hatası: $e");
    }
  }

  @override
  Future<GoogleSignInAccount?> signIn() async => null;

  @override
  Future<void> signOut() async {}
}
