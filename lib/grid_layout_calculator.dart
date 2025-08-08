import 'dart:math';

class GridLayout {
  final int columns;
  final int rows;

  const GridLayout({required this.columns, required this.rows});
}

class GridLayoutCalculator {
  static GridLayout calculate(int participants, {required bool isLandscape}) {
    if (participants < 1) {
      return const GridLayout(columns: 1, rows: 1);
    } else {
      final columns = (sqrt(participants)).ceil();
      final rows = (participants / columns).ceil();

      return isLandscape ? GridLayout(columns: columns, rows: rows) : GridLayout(columns: rows, rows: columns);
    }
  }
}
