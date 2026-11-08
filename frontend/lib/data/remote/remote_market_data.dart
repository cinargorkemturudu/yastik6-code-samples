import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:decimal/decimal.dart';
import 'package:yastik_alti/domain/models/value_objects/price_point.dart';
import 'package:yastik_alti/domain/models/value_objects/price_quote.dart';
import 'package:yastik_alti/domain/models/entities/asset.dart';
import 'package:yastik_alti/data/remote/remote_exceptions.dart';

import '../../core/app_log.dart';
import '../../core/env.dart';

class RemoteMarketData {
  final http.Client _client;
  final String _baseUrl;

  RemoteMarketData({required http.Client client, required String baseUrl})
    : _client = client,
      _baseUrl = baseUrl;

  Future<List<PriceQuote>> fetchLatestAll() async {
    final uri = Uri.parse('$_baseUrl/api/prices/market');

    try {
      final res = await _client.get(
        uri,
        headers: {
          'X-Mobile-Client-Key': Env.apiKey,
          'Content-Type': 'application/json',
        },
      );

      if (res.statusCode != 200) {
        AppLog.debug('HAM API YANITI: ${res.body}', domain: 'NETWORK');
        AppLog.insight('api_error');
        AppLog.error(
          'HTTP ${res.statusCode} from market API',
          domain: 'NETWORK',
        );

        throw RemoteHttpException(
          statusCode: res.statusCode,
          message: 'Failed to fetch market data.',
          responseBody: res.body,
        );
      }

      final dynamic decoded;
      try {
        decoded = jsonDecode(res.body);
      } on FormatException catch (e, stack) {
        AppLog.insight('api_parse_error');
        AppLog.error(
          'JSON Format Exception from market data',
          domain: 'NETWORK',
          error: e,
          stackTrace: stack,
        );

        throw RemoteParseException(
          message: 'Invalid JSON format from market data API.',
          responseBody: res.body,
        );
      }

      List<dynamic> list = [];
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map) {
        if (decoded.containsKey('items')) {
          list = decoded['items'] as List;
        } else if (decoded.containsKey('data')) {
          list = decoded['data'] as List;
        }
      }

      final parsedData = list
          .map((x) {
            try {
              return _quoteFromJson(x as Map<String, dynamic>);
            } catch (e, stack) {
              AppLog.error(
                'Data Integrity Failure: Failed to parse a market asset. Asset discarded. Payload: $x',
                domain: 'NETWORK',
                error: e,
                stackTrace: stack,
              );
              return null;
            }
          })
          .whereType<PriceQuote>()
          .toList();

      return parsedData;
    } catch (e, stack) {
      if (e is RemoteHttpException || e is RemoteParseException) {
        rethrow;
      }
      AppLog.error(
        'Unexpected error fetching market data',
        domain: 'NETWORK',
        error: e,
        stackTrace: stack,
      );
      throw RemoteParseException(
        message: 'Unexpected error in fetchLatestAll: $e',
      );
    }
  }

  Future<List<PricePoint>> fetchHistory({
    required String assetCode,
    required String range,
  }) async {
    final safeAssetCode = Uri.encodeComponent(assetCode);

    final uri = Uri.parse(
      '$_baseUrl/api/prices/history/$safeAssetCode',
    ).replace(queryParameters: {'range': range});

    AppLog.debug(
      'Dispatching History API Request to $uri for $assetCode',
      domain: 'NETWORK',
    );

    try {
      final res = await _client.get(
        uri,
        headers: {
          'X-Mobile-Client-Key': Env.apiKey,
          'Content-Type': 'application/json',
        },
      );

      if (res.statusCode != 200) {
        AppLog.insight('api_error');
        AppLog.error(
          'HTTP ${res.statusCode} from history API for $assetCode',
          domain: 'NETWORK',
        );

        throw RemoteHttpException(
          statusCode: res.statusCode,
          message: 'Failed to fetch history for $assetCode.',
          responseBody: res.body,
        );
      }

      final dynamic decoded;
      try {
        decoded = jsonDecode(res.body);
      } on FormatException catch (e, stack) {
        AppLog.insight('api_parse_error');
        AppLog.error(
          'JSON Format Exception from history API',
          domain: 'NETWORK',
          error: e,
          stackTrace: stack,
        );

        throw RemoteParseException(
          message: 'Invalid JSON format in history API.',
          responseBody: res.body,
        );
      }

      final data = decoded as Map<String, dynamic>;

      if (!data.containsKey('points')) {
        return [];
      }

      final List list = data['points'] as List;

      final parsedPoints = list
          .map((x) => _pointFromJson(x as Map<String, dynamic>))
          .toList(growable: false);

      return parsedPoints;
    } catch (e, stack) {
      if (e is RemoteHttpException || e is RemoteParseException) {
        rethrow;
      }
      AppLog.error(
        'Unexpected error fetching history for $assetCode',
        domain: 'NETWORK',
        error: e,
        stackTrace: stack,
      );
      throw RemoteParseException(
        message: 'Unexpected error in fetchHistory: $e',
      );
    }
  }

  PriceQuote _quoteFromJson(Map<String, dynamic> j) {
    final bidVal =
        Decimal.tryParse(j['bid']?.toString() ?? '0') ?? Decimal.zero;
    final askVal =
        Decimal.tryParse(j['ask']?.toString() ?? '0') ?? Decimal.zero;
    final changeRateVal = (j['changeRate'] as num?)?.toDouble() ?? 0.0;
    final convertedFlag = j['isConvertedToTry'] == true;
    final marketOpenFlag = j['isMarketOpen'] != false;

    final type = _mapType(j['type']?.toString());
    if (type == null) {
      throw FormatException(
        'Unknown or unsupported asset type received: ${j['type']}',
      );
    }

    final asOf = _parseUtc((j['asOfUtc'] ?? '').toString());
    final validUntilRaw = (j['validUntilUtc'] ?? '').toString();

    DateTime expiresAt = validUntilRaw.isNotEmpty
        ? _parseUtc(validUntilRaw)
        : asOf.add(const Duration(minutes: 15));

    return PriceQuote(
      assetCode: (j['productCode'] ?? '').toString(),
      name: (j['name'] ?? 'Unknown').toString(),
      type: type,
      bid: bidVal,
      ask: askVal,
      changeRate: changeRateVal,
      asOf: asOf,
      expiresAt: expiresAt,
      isConvertedtoTry: convertedFlag,
      isMarketOpen: marketOpenFlag,
    );
  }

  PricePoint _pointFromJson(Map<String, dynamic> j) {
    return PricePoint(
      timestamp: _parseUtc((j['timestampUtc'] ?? j['timestamp']).toString()),
      price: Decimal.tryParse(j['price']?.toString() ?? '0') ?? Decimal.zero,
    );
  }

  AssetType? _mapType(String? typeStr) {
    if (typeStr == null) return null;

    switch (typeStr.toUpperCase()) {
      case 'METAL':
        return AssetType.metal;
      case 'CURRENCY':
        return AssetType.currency;
      case 'STOCK':
        return AssetType.stock;
      case 'CRYPTO':
        return AssetType.crypto;
      case 'INDICATOR':
        return AssetType.indicator;
      default:
        return null;
    }
  }

  DateTime _parseUtc(String s) {
    if (s.isEmpty) return DateTime.now().toUtc();
    return DateTime.parse(s).toUtc();
  }
}
