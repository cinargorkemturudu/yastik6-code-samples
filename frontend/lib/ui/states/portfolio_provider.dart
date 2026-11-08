import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yastik_alti/core/app_log.dart';
import 'package:yastik_alti/di/providers.dart';
import 'package:yastik_alti/domain/models/dtos/asset_holding.dart';
import 'package:yastik_alti/domain/models/dtos/portfolio_data.dart';
import 'package:yastik_alti/domain/models/dtos/realized_profit.dart';
import 'package:yastik_alti/domain/models/entities/transaction.dart';
import 'package:yastik_alti/ui/states/live_price_provider.dart';
import 'package:yastik_alti/domain/models/dtos/market_state.dart';

// 1. Dart 3 record type: holds all DB data in a single payload.
typedef RawDbData = ({
List<AssetHolding> holdings,
List<Transaction> transactions,
Map<String, List<Map<String, dynamic>>> allocations,
PortfolioRealizedSummary realized,
});

// 2. One master provider instead of 4 separate providers
final _dbMasterProvider = FutureProvider<RawDbData>((ref) async {
  final service = ref.watch(portfolioServiceProvider);

  // Fetch the independent data in parallel
  final results = await Future.wait([
    service.getHoldings(),
    service.getAllTransactions(),
    service.getRealizedProfitReport(),
  ]);

  final holdings = results[0] as List<AssetHolding>;
  final transactions = results[1] as List<Transaction>;
  final realized = results[2] as PortfolioRealizedSummary;

  // Only the allocations, which depend on transactions, are fetched afterwards
  final allocations = await service.loadAllocationsMap(transactions);

  return (
  holdings: holdings,
  transactions: transactions,
  allocations: allocations,
  realized: realized,
  );
});

final portfolioProvider = NotifierProvider<PortfolioNotifier, PortfolioData>(PortfolioNotifier.new);

class PortfolioNotifier extends Notifier<PortfolioData> {

  @override
  PortfolioData build() {
    AppLog.debug('PortfolioEngine BUILD triggered. Gathering data...', domain: 'STATE');

    final marketState = ref.watch(livePriceProvider).valueOrNull ?? MarketState.initial();

    final dbAsync = ref.watch(_dbMasterProvider);

    // 1. Check for a failed read first
    if (dbAsync.hasError) {
      AppLog.error('Failed to read from the database: ${dbAsync.error}', domain: 'STATE', error: dbAsync.error);
      // Send the error payload to the UI. The UI can now see errorMessage and draw an error screen instead of loading forever.
      return PortfolioData.error('Veritabanı okunamadı. Lütfen uygulamayı yeniden başlatın.');
    }

    final db = dbAsync.valueOrNull;

    // 2. No error, but no data yet: still loading from the database.
    if (db == null) {
      return PortfolioData.initial();
    }

    AppLog.debug('Computing snapshot... (Holdings: ${db.holdings.length}, Prices: ${marketState.priceMap.length})', domain: 'STATE');

    final stopwatch = Stopwatch()..start();

    final snapshot = ref.read(portfolioServiceProvider).computeSnapshot(
      holdings: db.holdings,
      prices: marketState.priceMap,
    );

    stopwatch.stop();

    AppLog.info('Snapshot computed in ${stopwatch.elapsedMilliseconds}ms. Positions: ${snapshot.positions.length}', domain: 'STATE');

    if (!dbAsync.isLoading && db.holdings.isNotEmpty) {
      AppLog.insight('portfolio_calculated', metadata: {
        'duration_ms': stopwatch.elapsedMilliseconds,
        'holdings_count': db.holdings.length,
      });
    }

    return PortfolioData(
      snapshot: snapshot,
      realizedSummary: db.realized,
      transactions: db.transactions,
      allocationsMap: db.allocations,
      isLoading: dbAsync.isLoading,
      errorMessage: null, // All good, no error.
    );
  }

  void refreshDb() {
    AppLog.info('Database refresh requested. Invalidating Master Provider...', domain: 'STATE');
    AppLog.insight('portfolio_db_refresh');

    // Now only one provider has to be invalidated
    ref.invalidate(_dbMasterProvider);
  }
}