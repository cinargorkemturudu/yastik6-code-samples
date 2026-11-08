import 'package:decimal/decimal.dart';
import 'package:yastik_alti/domain/models/dtos/portfolio_snapshot.dart';
import 'package:yastik_alti/domain/models/dtos/realized_profit.dart';
import 'package:yastik_alti/domain/models/entities/asset.dart';
import 'package:yastik_alti/domain/models/entities/transaction.dart';
import '../ui_models/lot_ui_model.dart';
import '../ui_models/portfolio_donut_model.dart';
import '../utils/app_formatter.dart';
import '../theme/app_colors.dart';
import '../theme/app_strings.dart';

enum HistoryFilterType { all, buyOnly, sellOnly }

class UniversalPortfolioMapper {

  // HELPER METHOD: Centralizes the presentation logic for Lot titles
  static String _formatLotTitle(AssetType type, String rawName, String symbol) {
    if (type == AssetType.stock) {
      return symbol;
    }
    if (type == AssetType.metal) {
      return rawName;
    }
    return AppFormatter.cleanAssetCode(symbol);
  }

  // HELPER METHOD: Returns category display names
  static String _getCategoryName(AssetType type) {
    switch (type) {
      case AssetType.metal: return "Madenler";
      case AssetType.currency: return "Döviz";
      case AssetType.crypto: return "Kripto Paralar";
      case AssetType.stock: return "Hisse Senetleri";
      case AssetType.indicator: return "Göstergeler";
    }
  }

  static List<LotUiModel> toLotUiModels({
    required List<AssetPosition> positions,
    required Map<String, List<Map<String, dynamic>>> allocationsMap,
    required Map<String, String> assetNames,
    AssetType? assetFilter,
  }) {
    final List<LotUiModel> lots = [];

    for (final pos in positions) {
      if (assetFilter != null && pos.asset.type != assetFilter) continue;

      final rawName = assetNames[pos.asset.symbol] ?? pos.asset.name;
      final displayTitle = _formatLotTitle(pos.asset.type, rawName, pos.asset.symbol);

      for (final lotProfit in pos.lots) {
        final tx = lotProfit.transaction;

        final allocationUiModels = _toAllocationUiModels(tx, allocationsMap, pos.asset.symbol);

        lots.add(LotUiModel(
          transactionId: tx.id,
          dateText: AppFormatter.date(tx.purchaseDate),
          sortDate: tx.purchaseDate,
          note: tx.note,
          assetName: rawName,
          symbol: pos.asset.symbol,
          type: pos.asset.type,
          displayTitle: displayTitle,
          amountValue: tx.remainingAmount,
          originalAmountText: AppFormatter.amount(tx.amount, pos.asset.symbol),
          remainingAmountText: AppFormatter.amount(tx.remainingAmount, pos.asset.symbol),
          soldAmountText: AppFormatter.amount((tx.amount - tx.remainingAmount), pos.asset.symbol),
          buyPriceText: AppFormatter.money(tx.purchasePrice),
          totalCostText: AppFormatter.money(lotProfit.cost),
          profitPercent: AppFormatter.signedPercent(lotProfit.profitPct),
          currentUnrealizedPnl: AppFormatter.pnlValue(lotProfit.profit),
          unrealizedColor: lotProfit.profit.toPnlColor(),
          totalRealizedPnl: null,
          realizedColor: null,
          progressVal: tx.amount == Decimal.zero ? 0.0 : (tx.remainingAmount.toRational() / tx.amount.toRational()).toDouble(),
          isSellCard: false,
          allocations: allocationUiModels,
        ));
      }
    }

    lots.sort((a, b) => b.sortDate.compareTo(a.sortDate));
    return lots;
  }

  static List<SubTransactionUiModel> _toAllocationUiModels(
    Transaction tx,
    Map<String, List<Map<String, dynamic>>> allocationsMap,
    String symbol,
  ) {
    final rawAllocations = List<Map<String, dynamic>>.from(allocationsMap[tx.id] ?? []);
    rawAllocations.sort((a, b) {
      final dateA = DateTime.parse(a['sell_date'].toString());
      final dateB = DateTime.parse(b['sell_date'].toString());
      return dateB.compareTo(dateA);
    });

    return rawAllocations.map((row) {
      final date = DateTime.parse(row['sell_date'].toString());
      final amount = Decimal.parse(row['used_amount'].toString());
      final sellPrice = Decimal.parse(row['sell_price'].toString());
      final profit = (sellPrice - tx.purchasePrice) * amount;

      return SubTransactionUiModel(
        date: AppFormatter.date(date),
        amount: AppFormatter.amount(amount, symbol),
        price: AppFormatter.money(sellPrice),
        profitText: AppFormatter.pnlValue(profit),
        profitColor: profit.toPnlColor(),
      );
    }).toList();
  }

  static List<LotUiModel> toHistoryLots({
    required List<Transaction> allTransactions,
    required Map<String, List<Map<String, dynamic>>> allocationsMap,
    required Map<String, AssetType> assetTypes,
    required AssetType? assetFilter,
    required HistoryFilterType filterType,
    required Map<String, String> assetNames,
  }) {
    return allTransactions.where((tx) {
      if (filterType == HistoryFilterType.buyOnly && tx.type == TransactionType.sell) return false;
      if (filterType == HistoryFilterType.sellOnly && tx.type == TransactionType.buy) return false;
      return true;
    }).map((tx) {
      final type = assetTypes[tx.assetId] ?? AssetType.stock;
      final rawName = assetNames[tx.assetId] ?? tx.assetId;
      final displayTitle = _formatLotTitle(type, rawName, tx.assetId);

      return LotUiModel(
        transactionId: tx.id,
        dateText: AppFormatter.date(tx.purchaseDate),
        sortDate: tx.purchaseDate,
        assetName: rawName,
        symbol: tx.assetId,
        type: type,
        displayTitle: displayTitle,
        amountValue: tx.amount,
        originalAmountText: AppFormatter.amount(tx.amount, tx.assetId),
        remainingAmountText: AppFormatter.amount(tx.remainingAmount, tx.assetId),
        soldAmountText: AppFormatter.amount((tx.amount - tx.remainingAmount), tx.assetId),
        buyPriceText: AppFormatter.money(tx.purchasePrice),
        totalCostText: AppFormatter.money((tx.amount * tx.purchasePrice)),
        profitPercent: "",
        currentUnrealizedPnl: "",
        unrealizedColor: AppColors.textPrimary,
        progressVal: tx.amount == Decimal.zero ? 0.0 : (tx.remainingAmount.toRational() / tx.amount.toRational()).toDouble(),
        isSellCard: tx.type == TransactionType.sell,
        allocations: tx.type == TransactionType.buy
            ? _toAllocationUiModels(tx, allocationsMap, tx.assetId)
            : const [],
      );
    }).toList();
  }

  static PortfolioDonutModel toDonutModel(
      PortfolioSnapshot snapshot,
      AssetType? filter,
      Map<String, String> assetNames,
      ) {
    final items = snapshot.positions.where((p) {
      if (p.asset.type == AssetType.indicator) return false;
      if (filter == null) return true;
      return p.asset.type == filter;
    }).toList();

    final Decimal totalTl = filter == null ? snapshot.totalValue : items.fold(Decimal.zero, (sum, i) => sum + i.currentValue);
    final Decimal totalPnlTl = filter == null ? snapshot.totalProfit : items.fold(Decimal.zero, (sum, i) => sum + i.profit);
    final Decimal netCost = totalTl - totalPnlTl;
    final double totalPnlPct = filter == null ? snapshot.totalProfitPct : (netCost > Decimal.zero ? (totalPnlTl.toRational() / netCost.toRational()).toDouble() : 0.0);

    List<PortfolioDonutItem> donutItems = [];

    if (filter == null) {
      // PORTFOLIO OVERVIEW: group by category
      final Map<AssetType, Decimal> typeValues = {};
      final Map<AssetType, Decimal> typePnls = {};

      for (final pos in items) {
        final type = pos.asset.type;
        typeValues[type] = (typeValues[type] ?? Decimal.zero) + pos.currentValue;
        typePnls[type] = (typePnls[type] ?? Decimal.zero) + pos.profit;
      }

      final sortedEntries = typeValues.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

      donutItems = List.generate(sortedEntries.length, (index) {
        final type = sortedEntries[index].key;
        final tlValue = sortedEntries[index].value;
        final pnlTl = typePnls[type]!;
        final typeNetCost = tlValue - pnlTl;
        final pnlPct = typeNetCost > Decimal.zero ? (pnlTl.toRational() / typeNetCost.toRational()).toDouble() : 0.0;

        // Calculate Monochromatic Opacity (Min 25%)
        final safeAlpha = (1.0 - (index * 0.25)).clamp(0.25, 1.0);

        return PortfolioDonutItem(
          type: type,
          title: _getCategoryName(type),
          quantity: Decimal.zero, // Categories don't have a single quantity
          tlValue: tlValue,
          pnlTl: pnlTl,
          pnlPct: pnlPct,
          color: AppColors.brandBlue.withValues(alpha: safeAlpha),
        );
      });
    } else {
      // CATEGORY DETAIL: group by asset 
      final sortedItems = List<AssetPosition>.from(items)..sort((a, b) => b.currentValue.compareTo(a.currentValue));

      donutItems = List.generate(sortedItems.length, (index) {
        final pos = sortedItems[index];
        final rawName = assetNames[pos.asset.symbol] ?? pos.asset.name;
        final isStock = pos.asset.type == AssetType.stock;
        final isMetal = pos.asset.type == AssetType.metal;
        final displayName = isStock ? pos.asset.symbol : (isMetal ? rawName : AppFormatter.cleanAssetCode(pos.asset.symbol));

        final safeAlpha = (1.0 - (index * 0.20)).clamp(0.20, 1.0);

        return PortfolioDonutItem(
          type: pos.asset.type,
          title: displayName,
          quantity: pos.totalAmount,
          tlValue: pos.currentValue,
          pnlTl: pos.profit,
          pnlPct: pos.profitPct,
          color: AppColors.brandBlue.withValues(alpha: safeAlpha),
        );
      });
    }

    return PortfolioDonutModel(
      totalTl: totalTl,
      totalPnlTl: totalPnlTl,
      totalPnlPct: totalPnlPct,
      totalValueText: AppFormatter.money(totalTl),
      totalPnlText: "${AppFormatter.pnlValue(totalPnlTl)} (${AppFormatter.signedPercent(totalPnlPct)})",
      pnlColor: totalPnlTl.toPnlColor(),
      items: donutItems,
    );
  }

  static PortfolioDonutModel toRealizedDonutModel(PortfolioRealizedSummary summary, AssetType? filter, Map<String, String> assetNames,) {
    final items = summary.assetSummaries.where((s) {
      if (s.assetType == AssetType.indicator) return false;
      if (filter == null) return true;
      return s.assetType == filter;
    }).toList();

    final Decimal totalTl = filter == null ? summary.totalLifetimeProfit : items.fold(Decimal.zero, (sum, i) => sum + i.totalProfit);

    List<PortfolioDonutItem> donutItems = [];

    if (filter == null) {
      final Map<AssetType, Decimal> typeValues = {};

      for (final asset in items) {
        final type = asset.assetType;
        typeValues[type] = (typeValues[type] ?? Decimal.zero) + asset.totalProfit;
      }

      final sortedEntries = typeValues.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

      donutItems = List.generate(sortedEntries.length, (index) {
        final type = sortedEntries[index].key;
        final pnlTl = sortedEntries[index].value;
        final safeAlpha = (1.0 - (index * 0.25)).clamp(0.25, 1.0);

        return PortfolioDonutItem(
          type: type,
          title: _getCategoryName(type),
          quantity: Decimal.zero,
          tlValue: pnlTl,
          pnlTl: pnlTl,
          pnlPct: 0.0,
          color: AppColors.brandBlue.withValues(alpha: safeAlpha),
        );
      });
    } else {
      final sortedItems = List.from(items)..sort((a, b) => (b as dynamic).totalProfit.compareTo((a as dynamic).totalProfit));

      donutItems = List.generate(sortedItems.length, (index) {
        final asset = sortedItems[index];
        final rawName = assetNames[asset.symbol] ?? asset.symbol;
        final isStock = asset.assetType == AssetType.stock;
        final isMetal = asset.assetType == AssetType.metal;
        final displayName = isStock ? asset.symbol : (isMetal ? rawName : AppFormatter.cleanAssetCode(asset.symbol));

        final safeAlpha = (1.0 - (index * 0.20)).clamp(0.20, 1.0);

        return PortfolioDonutItem(
          type: asset.assetType,
          title: displayName,
          quantity: asset.totalAmountSold,
          tlValue: asset.totalProfit,
          pnlTl: asset.totalProfit,
          pnlPct: asset.itemPnlPct,
          color: AppColors.brandBlue.withValues(alpha: safeAlpha),
        );
      });
    }

    return PortfolioDonutModel(
      totalTl: totalTl,
      totalPnlTl: totalTl,
      totalPnlPct: summary.totalPnlPct,
      totalValueText: AppFormatter.money(totalTl),
      totalPnlText: "${AppFormatter.pnlValue(totalTl)} (${AppFormatter.signedPercent(summary.totalPnlPct)})",
      pnlColor: totalTl.toPnlColor(),
      items: donutItems,
    );
  }

  static List<LotUiModel> toRealizedLotUiModels({
    required PortfolioRealizedSummary summary,
    required Map<String, String> assetNames,
    AssetType? assetFilter,
  }) {
    final List<LotUiModel> lots = [];

    for (final assetSummary in summary.assetSummaries) {
      if (assetFilter != null && assetSummary.assetType != assetFilter) continue;

      final rawName = assetNames[assetSummary.symbol] ?? assetSummary.symbol;
      final displayTitle = _formatLotTitle(assetSummary.assetType, rawName, assetSummary.symbol);

      for (final tx in assetSummary.transactions) {
        lots.add(LotUiModel(
          transactionId: tx.sellTransactionId,
          dateText: AppFormatter.date(tx.date),
          sortDate: tx.date,
          note: AppStrings.labels.profitRealization,
          assetName: rawName,
          symbol: assetSummary.symbol,
          type: assetSummary.assetType,
          displayTitle: displayTitle,
          amountValue: Decimal.zero,
          originalAmountText: AppFormatter.amount(tx.amountSold, assetSummary.symbol),
          remainingAmountText: AppFormatter.amount(Decimal.zero, ""),
          soldAmountText: AppFormatter.amount(tx.amountSold, assetSummary.symbol),
          buyPriceText: AppFormatter.money(tx.avgBuyPrice),
          totalCostText: AppFormatter.money((tx.sellPrice * tx.amountSold)),
          profitPercent: AppFormatter.signedPercent(tx.profitPct),
          totalRealizedPnl: AppFormatter.pnlValue(tx.profit),
          realizedColor: tx.profit.toPnlColor(),
          currentUnrealizedPnl: null,
          unrealizedColor: null,
          progressVal: 0.0,
          isSellCard: false,
        ));
      }
    }

    lots.sort((a, b) => b.sortDate.compareTo(a.sortDate));
    return lots;
  }
}