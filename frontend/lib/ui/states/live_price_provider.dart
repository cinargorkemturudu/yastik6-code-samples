import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yastik_alti/core/app_log.dart';
import 'package:yastik_alti/di/providers.dart';
import 'package:yastik_alti/domain/models/dtos/market_state.dart';
import 'package:yastik_alti/domain/models/value_objects/price_quote.dart';

final livePriceProvider = AsyncNotifierProvider<LivePriceNotifier, MarketState>(
  LivePriceNotifier.new,
);

class LivePriceNotifier extends AsyncNotifier<MarketState> {
  Timer? _timer;

  @override
  Future<MarketState> build() async {
    AppLog.debug(
      'LivePriceNotifier built: Starting price service',
      domain: 'STATE',
    );
    AppLog.insight('live_price_service_started');

    ref.onDispose(() {
      AppLog.debug(
        'LivePriceNotifier disposed: Canceling timer',
        domain: 'STATE',
      );
      _timer?.cancel();
    });

    final service = ref.read(priceServiceProvider);

    // 1. LOAD THE CACHE SO THE UI CAN DRAW IMMEDIATELY
    var current = MarketState.initial();
    final cachedQuotes = await service.getCachedAll();
    if (cachedQuotes.isNotEmpty) {
      AppLog.info(
        'Loaded ${cachedQuotes.length} items from offline cache.',
        domain: 'STATE',
      );
      current = MarketState(
        marketAssets: cachedQuotes,
        priceMap: {for (var q in cachedQuotes) q.assetCode: q},
      );
      state = AsyncData(current);
    }

    // 2. START THE LIVE DATA LOOP IN THE BACKGROUND
    _timer ??= Timer.periodic(const Duration(seconds: 10), (_) => _refresh());

    // 3. MAKE THE FIRST NETWORK REQUEST (continue with cached data if it fails)
    return _attemptFetch(current);
  }

  Future<List<PriceQuote>> _fetchQuotes() {
    final service = ref.read(priceServiceProvider);
    return service.getLatestAll();
  }

  Future<void> _refresh() async {
    AppLog.debug('Polling new prices from API (10s interval)', domain: 'STATE');
    final previous = state.valueOrNull ?? MarketState.initial();
    state = AsyncData(await _attemptFetch(previous));
  }

  /// Fetches fresh quotes. On success, replaces the snapshot and resets the
  /// failure streak. On failure, keeps [previous]'s data but still records the
  /// attempt, so the UI can tell "haven't synced yet" apart from "sync is failing".
  Future<MarketState> _attemptFetch(MarketState previous) async {
    final attemptTime = DateTime.now();

    try {
      final quotes = await _fetchQuotes();

      AppLog.info(
        'Market state updated successfully with ${quotes.length} assets',
        domain: 'STATE',
      );
      AppLog.insight('live_price_refreshed');

      return MarketState(
        marketAssets: quotes,
        priceMap: {for (var q in quotes) q.assetCode: q},
        lastUpdate: attemptTime,
        lastAttempt: attemptTime,
        consecutiveFailures: 0,
      );
    } catch (e, stack) {
      AppLog.warning(
        'Failed to fetch new prices, preserving old state',
        domain: 'STATE',
      );
      AppLog.error(
        'Price refresh error',
        domain: 'STATE',
        error: e,
        stackTrace: stack,
      );
      AppLog.insight('live_price_refresh_failed');

      return previous.copyWith(
        lastAttempt: attemptTime,
        consecutiveFailures: previous.consecutiveFailures + 1,
      );
    }
  }
}
