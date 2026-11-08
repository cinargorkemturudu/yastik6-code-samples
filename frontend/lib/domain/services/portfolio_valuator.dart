import 'package:decimal/decimal.dart';
import 'package:yastik_alti/domain/models/dtos/asset_holding.dart';
import 'package:yastik_alti/domain/models/dtos/portfolio_snapshot.dart';
import 'package:yastik_alti/domain/models/value_objects/price_quote.dart';
import 'package:yastik_alti/domain/models/entities/asset.dart';

class PortfolioValuator {
  static PortfolioSnapshot compute({
    required List<AssetHolding> holdings,
    required Map<String, PriceQuote> prices,
  }) {
    Decimal totalCost = Decimal.zero;
    Decimal totalValue = Decimal.zero;
    final List<AssetPosition> positions = [];

    for (final holding in holdings) {
      if (holding.asset.type == AssetType.indicator) continue;

      final symbol = holding.asset.symbol;
      final quote = prices[symbol];

      Decimal currentPrice = quote?.bid ?? Decimal.zero;

      if (currentPrice <= Decimal.zero) {
        // [FIXED] Fallback to the last known database price instead of average cost
        currentPrice = holding.asset.currentPrice;
      }

      final currentValue = holding.totalAmount * currentPrice;
      final profit = currentValue - holding.totalCost;
      final profitPct = holding.totalCost == Decimal.zero ? Decimal.zero : (profit.toRational() / holding.totalCost.toRational()).toDecimal(scaleOnInfinitePrecision: 10);

      final lotProfits = holding.activeLots.map((lot) {
        final lotRemainingAmount = lot.remainingAmount;
        final lotPurchasePrice = lot.purchasePrice;

        final lotValue = lotRemainingAmount * currentPrice;
        final lotCost = lotRemainingAmount * lotPurchasePrice;
        final lotProfit = lotValue - lotCost;
        final lotPct = lotCost == Decimal.zero ? Decimal.zero : (lotProfit.toRational() / lotCost.toRational()).toDecimal(scaleOnInfinitePrecision: 10);

        return LotProfit(
          transaction: lot,
          asset: holding.asset,
          cost: lotCost,
          currentValue: lotValue,
          profit: lotProfit,
          profitPct: lotPct.toDouble(),
        );
      }).toList();

      positions.add(AssetPosition(
        asset: holding.asset,
        totalAmount: holding.totalAmount,
        averageBuyPrice: holding.avgCost,
        currentPrice: currentPrice,
        costBasis: holding.totalCost,
        currentValue: currentValue,
        profit: profit,
        profitPct: profitPct.toDouble(),
        lots: lotProfits,
      ));

      totalCost += holding.totalCost;
      totalValue += currentValue;
    }

    final totalProfit = totalValue - totalCost;
    final totalProfitPct = totalCost == Decimal.zero ? Decimal.zero : (totalProfit.toRational() / totalCost.toRational()).toDecimal(scaleOnInfinitePrecision: 10);

    return PortfolioSnapshot(
      positions: positions,
      totalCost: totalCost,
      totalValue: totalValue,
      totalProfit: totalProfit,
      totalProfitPct: totalProfitPct.toDouble(),
    );
  }
}