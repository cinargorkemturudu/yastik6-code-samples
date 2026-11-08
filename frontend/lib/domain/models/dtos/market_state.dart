import 'package:yastik_alti/domain/models/value_objects/price_quote.dart';
import 'package:yastik_alti/domain/models/entities/asset.dart'; // Added for AssetType

enum DataHealthStatus {
  healthy, // All categories are fresh (under 25% stale)
  degraded, // At least one category has >= 25% stale assets
  offline, // No data available or completely stale
}

class MarketState {
  final List<PriceQuote> marketAssets;
  final Map<String, PriceQuote> priceMap;
  final DateTime? lastUpdate;
  final DateTime? lastAttempt;
  final int consecutiveFailures;

  const MarketState({
    this.marketAssets = const [],
    this.priceMap = const {},
    this.lastUpdate,
    this.lastAttempt,
    this.consecutiveFailures = 0,
  });

  factory MarketState.initial() {
    return const MarketState();
  }

  // Grouped logic moved from the UI to the State
  Map<AssetType, DateTime> get categoryLastUpdates {
    final updates = <AssetType, DateTime>{};
    for (final quote in marketAssets) {
      if (!updates.containsKey(quote.type) ||
          quote.asOf.isAfter(updates[quote.type]!)) {
        updates[quote.type] = quote.asOf;
      }
    }
    return updates;
  }

  // The new 25% Stale Rule per provider/category
  Set<AssetType> get staleCategories {
    final staleTypes = <AssetType>{};
    final categoryCounts = <AssetType, int>{};
    final staleCounts = <AssetType, int>{};

    for (final quote in marketAssets) {
      categoryCounts[quote.type] = (categoryCounts[quote.type] ?? 0) + 1;
      if (quote.isStale) {
        staleCounts[quote.type] = (staleCounts[quote.type] ?? 0) + 1;
      }
    }

    for (final type in categoryCounts.keys) {
      final total = categoryCounts[type]!;
      final stale = staleCounts[type] ?? 0;

      // If 25% or more of the assets in this category are stale, the category is stale
      if ((stale / total) >= 0.25) {
        staleTypes.add(type);
      }
    }
    return staleTypes;
  }

  DataHealthStatus get healthStatus {
    if (marketAssets.isEmpty) return DataHealthStatus.offline;

    final staleCount = marketAssets.where((q) => q.isStale).length;
    if (staleCount == marketAssets.length) return DataHealthStatus.offline;

    // If any provider/category hit the 25% threshold, the system is degraded
    if (staleCategories.isNotEmpty) {
      return DataHealthStatus.degraded;
    }

    return DataHealthStatus.healthy;
  }

  MarketState copyWith({
    List<PriceQuote>? marketAssets,
    Map<String, PriceQuote>? priceMap,
    DateTime? lastUpdate,
    DateTime? lastAttempt,
    int? consecutiveFailures,
  }) {
    return MarketState(
      marketAssets: marketAssets ?? this.marketAssets,
      priceMap: priceMap ?? this.priceMap,
      lastUpdate: lastUpdate ?? this.lastUpdate,
      lastAttempt: lastAttempt ?? this.lastAttempt,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
    );
  }
}
