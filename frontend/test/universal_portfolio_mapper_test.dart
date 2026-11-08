import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yastik_alti/domain/models/entities/asset.dart';
import 'package:yastik_alti/domain/models/entities/transaction.dart';
import 'package:yastik_alti/ui/mappers/universal_portfolio_mapper.dart';

Transaction _makeTx({
  required String id,
  required TransactionType type,
  required Decimal amount,
  required Decimal remainingAmount,
}) => Transaction(
  id: id,
  assetId: 'USDTRY=X',
  type: type,
  amount: amount,
  purchasePrice: Decimal.fromInt(40),
  purchaseDate: DateTime.utc(2026, 1, 1),
  remainingAmount: remainingAmount,
);

void main() {
  group('UniversalPortfolioMapper.toHistoryLots', () {
    final buy = _makeTx(
      id: 'buy1',
      type: TransactionType.buy,
      amount: Decimal.fromInt(5),
      remainingAmount: Decimal.fromInt(2),
    );
    final sell = _makeTx(
      id: 'sell1',
      type: TransactionType.sell,
      amount: Decimal.fromInt(3),
      remainingAmount: Decimal.zero,
    );
    final allocationsMap = {
      'buy1': [
        {'used_amount': 1, 'sell_date': '2026-02-01T00:00:00.000', 'sell_price': '42'},
        {'used_amount': 2, 'sell_date': '2026-03-01T00:00:00.000', 'sell_price': '45'},
      ],
    };

    List<dynamic> map() => UniversalPortfolioMapper.toHistoryLots(
      allTransactions: [buy, sell],
      allocationsMap: allocationsMap,
      assetTypes: const {'USDTRY=X': AssetType.currency},
      assetFilter: null,
      filterType: HistoryFilterType.all,
      assetNames: const {},
    );

    test('buy lot carries its sell allocations, newest first', () {
      final lot = map().firstWhere((l) => l.transactionId == 'buy1');
      expect(lot.allocations, hasLength(2));
      expect(lot.allocations.first.date, '01.03.26');
      expect(lot.allocations.first.amount, contains('2'));
    });

    test('buy lot reflects sold amount and remaining progress', () {
      final lot = map().firstWhere((l) => l.transactionId == 'buy1');
      expect(lot.soldAmountText, contains('3'));
      expect(lot.progressVal, closeTo(0.4, 1e-9));
    });

    test('sell card has no allocations', () {
      final lot = map().firstWhere((l) => l.transactionId == 'sell1');
      expect(lot.isSellCard, isTrue);
      expect(lot.allocations, isEmpty);
    });
  });
}
