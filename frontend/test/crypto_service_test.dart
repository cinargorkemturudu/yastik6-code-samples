import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yastik_alti/core/crypto_service.dart';

void main() {
  // Low iteration count keeps the tests fast; production uses CryptoService.defaultIterations.
  final crypto = CryptoService(iterations: 1000);
  final data = utf8.encode('SQLite format 3\u0000 portfolio rows');

  group('CryptoService backup encryption', () {
    test('round-trips with the right passphrase', () async {
      final payload = await crypto.encryptBackup(data, 'correct horse');

      expect(await crypto.decryptBackup(payload, 'correct horse'), data);
    });

    test('does not contain the plaintext', () async {
      final payload = await crypto.encryptBackup(data, 'correct horse');

      expect(
        utf8.decode(payload, allowMalformed: true),
        isNot(contains('portfolio rows')),
      );
    });

    test(
      'a different device can decrypt with the same passphrase (no device-bound key)',
      () async {
        final payload = await crypto.encryptBackup(data, 'correct horse');
        final otherDevice = CryptoService(iterations: 5000);

        // Decryption uses the iteration count stored in the file, not the instance's own setting
        expect(await otherDevice.decryptBackup(payload, 'correct horse'), data);
      },
    );

    test('rejects a wrong passphrase', () async {
      final payload = await crypto.encryptBackup(data, 'correct horse');

      expect(
        crypto.decryptBackup(payload, 'wrong horse'),
        throwsA(isA<BackupDecryptionException>()),
      );
    });

    test('rejects a corrupted body', () async {
      final payload = await crypto.encryptBackup(data, 'correct horse');
      payload[payload.length - 20] ^= 0x01;

      expect(
        crypto.decryptBackup(payload, 'correct horse'),
        throwsA(isA<BackupDecryptionException>()),
      );
    });

    test('rejects a tampered header', () async {
      final payload = await crypto.encryptBackup(data, 'correct horse');
      payload[12] ^= 0x01; // inside the salt

      expect(
        crypto.decryptBackup(payload, 'correct horse'),
        throwsA(isA<BackupDecryptionException>()),
      );
    });

    test(
      'rejects files that are not Yastık6 backups, including the old iv:ciphertext text format',
      () async {
        final legacy = Uint8List.fromList(
          utf8.encode(
            '${base64.encode(List.filled(16, 1))}:${base64.encode(List.filled(64, 2))}',
          ),
        );

        expect(
          crypto.decryptBackup(legacy, 'correct horse'),
          throwsA(isA<FormatException>()),
        );
        expect(
          crypto.decryptBackup(Uint8List(10), 'correct horse'),
          throwsA(isA<FormatException>()),
        );
      },
    );
  });
}
