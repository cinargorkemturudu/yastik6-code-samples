import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yastik_alti/domain/models/dtos/asset_holding.dart';
import 'package:yastik_alti/domain/models/entities/asset.dart';
import 'package:yastik_alti/domain/models/entities/transaction.dart';
import 'package:yastik_alti/domain/models/value_objects/price_quote.dart';
import 'package:yastik_alti/domain/services/portfolio_valuator.dart';

Asset _makeAsset({
  required String symbol,
  AssetType type = AssetType.metal,
  Decimal? currentPrice,
}) => Asset(
  id: symbol,
  name: symbol,
  symbol: symbol,
  type: type,
  currentPrice: currentPrice ?? Decimal.zero,
  lastUpdate: DateTime.utc(2026, 1, 1),
);

Transaction _makeLot({
  required String assetId,
  required Decimal amount,
  required Decimal purchasePrice,
  Decimal? remainingAmount,
}) => Transaction(
  id: '${assetId}_lot_${purchasePrice.toString()}',
  assetId: assetId,
  type: TransactionType.buy,
  amount: amount,
  purchasePrice: purchasePrice,
  purchaseDate: DateTime.utc(2026, 1, 1),
  remainingAmount: remainingAmount ?? amount,
);

PriceQuote _makeQuote({
  required String assetCode,
  required Decimal bid,
  Decimal? ask,
  AssetType type = AssetType.metal,
}) => PriceQuote(
  assetCode: assetCode,
  name: assetCode,
  type: type,
  bid: bid,
  ask: ask ?? bid,
  changeRate: 0,
  asOf: DateTime.utc(2026, 1, 1),
  expiresAt: DateTime.utc(2026, 1, 1).add(const Duration(minutes: 5)),
);

void main() {
  group('PortfolioValuator.compute', () {
    test('computes value and profit for a single profitable holding', () {
      final asset = _makeAsset(
        symbol: 'GRAM_ALTIN',
        currentPrice: Decimal.parse('100'),
      );
      final lot = _makeLot(
        assetId: asset.id,
        amount: Decimal.parse('10'),
        purchasePrice: Decimal.parse('100'),
      );
      final holding = AssetHolding(
        asset: asset,
        totalAmount: Decimal.parse('10'),
        totalCost: Decimal.parse('1000'),
        avgCost: Decimal.parse('100'),
        activeLots: [lot],
      );
      final prices = {
        'GRAM_ALTIN': _makeQuote(
          assetCode: 'GRAM_ALTIN',
          bid: Decimal.parse('150'),
        ),
      };

      final snapshot = PortfolioValuator.compute(
        holdings: [holding],
        prices: prices,
      );

      final position = snapshot.positions.single;
      expect(position.currentValue, Decimal.parse('1500'));
      expect(position.profit, Decimal.parse('500'));
      expect(position.profitPct, closeTo(0.5, 0.0001));
      expect(snapshot.totalValue, Decimal.parse('1500'));
      expect(snapshot.totalCost, Decimal.parse('1000'));
      expect(snapshot.totalProfit, Decimal.parse('500'));
      expect(snapshot.totalProfitPct, closeTo(0.5, 0.0001));
    });

    test('computes a negative profit when the price has dropped', () {
      final asset = _makeAsset(
        symbol: 'GRAM_ALTIN',
        currentPrice: Decimal.parse('100'),
      );
      final holding = AssetHolding(
        asset: asset,
        totalAmount: Decimal.parse('10'),
        totalCost: Decimal.parse('1000'),
        avgCost: Decimal.parse('100'),
        activeLots: const [],
      );
      final prices = {
        'GRAM_ALTIN': _makeQuote(
          assetCode: 'GRAM_ALTIN',
          bid: Decimal.parse('80'),
        ),
      };

      final snapshot = PortfolioValuator.compute(
        holdings: [holding],
        prices: prices,
      );

      final position = snapshot.positions.single;
      expect(position.profit, Decimal.parse('-200'));
      expect(position.profitPct, closeTo(-0.2, 0.0001));
    });

    test('skips indicator-type assets entirely (not a real holding)', () {
      final asset = _makeAsset(
        symbol: 'ONS',
        type: AssetType.indicator,
        currentPrice: Decimal.parse('100'),
      );
      final holding = AssetHolding(
        asset: asset,
        totalAmount: Decimal.parse('1'),
        totalCost: Decimal.parse('100'),
        avgCost: Decimal.parse('100'),
        activeLots: const [],
      );

      final snapshot = PortfolioValuator.compute(
        holdings: [holding],
        prices: {},
      );

      expect(snapshot.positions, isEmpty);
      expect(snapshot.totalValue, Decimal.zero);
      expect(snapshot.totalCost, Decimal.zero);
    });

    test(
      'falls back to the asset\'s last known price when no live quote exists',
      () {
        final asset = _makeAsset(
          symbol: 'BTC-USD',
          type: AssetType.crypto,
          currentPrice: Decimal.parse('200'),
        );
        final holding = AssetHolding(
          asset: asset,
          totalAmount: Decimal.parse('2'),
          totalCost: Decimal.parse('300'),
          avgCost: Decimal.parse('150'),
          activeLots: const [],
        );

        // No entry for 'BTC-USD' in prices at all
        final snapshot = PortfolioValuator.compute(
          holdings: [holding],
          prices: {},
        );

        final position = snapshot.positions.single;
        expect(position.currentPrice, Decimal.parse('200'));
        expect(position.currentValue, Decimal.parse('400'));
      },
    );

    test(
      'falls back to the asset\'s last known price when the live quote bid is zero',
      () {
        final asset = _makeAsset(
          symbol: 'BTC-USD',
          type: AssetType.crypto,
          currentPrice: Decimal.parse('200'),
        );
        final holding = AssetHolding(
          asset: asset,
          totalAmount: Decimal.parse('2'),
          totalCost: Decimal.parse('300'),
          avgCost: Decimal.parse('150'),
          activeLots: const [],
        );
        final prices = {
          'BTC-USD': _makeQuote(
            assetCode: 'BTC-USD',
            bid: Decimal.zero,
            type: AssetType.crypto,
          ),
        };

        final snapshot = PortfolioValuator.compute(
          holdings: [holding],
          prices: prices,
        );

        final position = snapshot.positions.single;
        expect(position.currentPrice, Decimal.parse('200'));
      },
    );

    test('aggregates totals across multiple holdings', () {
      final winner = _makeAsset(
        symbol: 'GRAM_ALTIN',
        currentPrice: Decimal.parse('100'),
      );
      final loser = _makeAsset(
        symbol: 'BTC-USD',
        type: AssetType.crypto,
        currentPrice: Decimal.parse('50'),
      );

      final holdings = [
        AssetHolding(
          asset: winner,
          totalAmount: Decimal.parse('10'),
          totalCost: Decimal.parse('1000'),
          avgCost: Decimal.parse('100'),
          activeLots: const [],
        ),
        AssetHolding(
          asset: loser,
          totalAmount: Decimal.parse('4'),
          totalCost: Decimal.parse('200'),
          avgCost: Decimal.parse('50'),
          activeLots: const [],
        ),
      ];
      final prices = {
        'GRAM_ALTIN': _makeQuote(
          assetCode: 'GRAM_ALTIN',
          bid: Decimal.parse('150'),
        ), // +500
        'BTC-USD': _makeQuote(
          assetCode: 'BTC-USD',
          bid: Decimal.parse('25'),
          type: AssetType.crypto,
        ), // -100
      };

      final snapshot = PortfolioValuator.compute(
        holdings: holdings,
        prices: prices,
      );

      expect(snapshot.positions, hasLength(2));
      expect(snapshot.totalCost, Decimal.parse('1200'));
      expect(snapshot.totalValue, Decimal.parse('1600')); // 1500 + 100
      expect(snapshot.totalProfit, Decimal.parse('400')); // 500 - 100
    });

    test('breaks down profit per lot within a holding', () {
      final asset = _makeAsset(
        symbol: 'GRAM_ALTIN',
        currentPrice: Decimal.parse('100'),
      );
      final cheapLot = _makeLot(
        assetId: asset.id,
        amount: Decimal.parse('5'),
        purchasePrice: Decimal.parse('100'),
      );
      final expensiveLot = _makeLot(
        assetId: asset.id,
        amount: Decimal.parse('5'),
        purchasePrice: Decimal.parse('120'),
      );
      final holding = AssetHolding(
        asset: asset,
        totalAmount: Decimal.parse('10'),
        totalCost: Decimal.parse('1100'),
        avgCost: Decimal.parse('110'),
        activeLots: [cheapLot, expensiveLot],
      );
      final prices = {
        'GRAM_ALTIN': _makeQuote(
          assetCode: 'GRAM_ALTIN',
          bid: Decimal.parse('150'),
        ),
      };

      final snapshot = PortfolioValuator.compute(
        holdings: [holding],
        prices: prices,
      );

      final lots = snapshot.positions.single.lots;
      expect(lots, hasLength(2));
      expect(lots[0].profit, Decimal.parse('250')); // 5*150 - 5*100
      expect(lots[1].profit, Decimal.parse('150')); // 5*150 - 5*120
    });

    test('does not divide by zero when total cost is zero', () {
      final asset = _makeAsset(
        symbol: 'FREE_AIRDROP',
        type: AssetType.crypto,
        currentPrice: Decimal.parse('10'),
      );
      final holding = AssetHolding(
        asset: asset,
        totalAmount: Decimal.parse('5'),
        totalCost: Decimal.zero,
        avgCost: Decimal.zero,
        activeLots: const [],
      );
      final prices = {
        'FREE_AIRDROP': _makeQuote(
          assetCode: 'FREE_AIRDROP',
          bid: Decimal.parse('10'),
          type: AssetType.crypto,
        ),
      };

      final snapshot = PortfolioValuator.compute(
        holdings: [holding],
        prices: prices,
      );

      expect(snapshot.positions.single.profitPct, 0.0);
      expect(snapshot.totalProfitPct, 0.0);
    });
  });
}
