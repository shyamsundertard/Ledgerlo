import 'package:intl/intl.dart';

class CalculatorSession {
  String expression = '';

  void clear() {
    expression = '';
  }

  void backspace() {
    if (expression.isNotEmpty) expression = expression.substring(0, expression.length - 1);
  }

  void appendDigit(String d) {
    expression = '$expression$d';
  }

  void appendDot() {
    // only allow dot if current number doesn't contain one
    final lastNumber = _lastNumber();
    if (!lastNumber.contains('.')) {
      if (lastNumber.isEmpty) {
        expression = '${expression}0.';
      } else {
        expression = '$expression.';
      }
    }
  }

  void appendOperator(String op) {
    // normalize operators to + - * /
    final mapped = (op == '×') ? '*' : (op == '÷') ? '/' : op;
    if (expression.isEmpty) {
      if (mapped == '-') expression = '-';
      return;
    }
    final last = expression[expression.length - 1];
    if (last == '+' || last == '-' || last == '*' || last == '/') {
      // replace
      expression = '${expression.substring(0, expression.length - 1)}$mapped';
    } else {
      expression = '$expression$mapped';
    }
  }

  String _lastNumber() {
    var i = expression.length - 1;
    final sb = StringBuffer();
    while (i >= 0) {
      final ch = expression[i];
      if (isDigit(ch) || ch == '.') {
        sb.write(ch);
        i--;
      } else {
        break;
      }
    }
    return sb.toString().split('').reversed.join();
  }

  double? evaluate() {
    if (expression.isEmpty) return null;
    try {
      // ignore trailing operators so pressing an operator doesn't make result 0
      var expr = expression.replaceAll('×', '*').replaceAll('÷', '/');
      while (expr.isNotEmpty && '+-*/'.contains(expr[expr.length - 1])) {
        expr = expr.substring(0, expr.length - 1);
      }
      if (expr.isEmpty) return null;
      final tokens = <String>[];
      // tokenize
      for (var i = 0; i < expr.length; ) {
        final ch = expr[i];
        if (ch == '+' || ch == '-' || ch == '*' || ch == '/') {
          // handle unary minus
          if (ch == '-' && (i == 0 || '+-*/'.contains(expr[i - 1]))) {
            // part of number
            var j = i + 1;
            final sb = StringBuffer('-');
            while (j < expr.length && (isDigit(expr[j]) || expr[j] == '.')) {
              sb.write(expr[j]);
              j++;
            }
            tokens.add(sb.toString());
            i = j;
            continue;
          } else {
            tokens.add(ch);
            i++;
            continue;
          }
        } else if (isDigit(ch) || ch == '.') {
          var j = i;
          final sb = StringBuffer();
          while (j < expr.length && (isDigit(expr[j]) || expr[j] == '.')) {
            sb.write(expr[j]);
            j++;
          }
          tokens.add(sb.toString());
          i = j;
          continue;
        } else {
          // skip unknown
          i++;
        }
      }

      // shunting-yard to RPN
      final out = <String>[];
      final ops = <String>[];
      int prec(String o) => (o == '+' || o == '-') ? 1 : 2;
      for (final t in tokens) {
        if (t.isEmpty) continue;
        if (t == '+' || t == '-' || t == '*' || t == '/') {
          while (ops.isNotEmpty && prec(ops.last) >= prec(t)) {
            out.add(ops.removeLast());
          }
          ops.add(t);
        } else {
          out.add(t);
        }
      }
      while (ops.isNotEmpty) {
        out.add(ops.removeLast());
      }

      // evaluate RPN
      final stack = <double>[];
      for (final t in out) {
        if (t == '+' || t == '-' || t == '*' || t == '/') {
          if (stack.length < 2) return null;
          final b = stack.removeLast();
          final a = stack.removeLast();
          double r;
          switch (t) {
            case '+': r = a + b; break;
            case '-': r = a - b; break;
            case '*': r = a * b; break;
            case '/': r = b == 0 ? 0 : a / b; break;
            default: r = b;
          }
          stack.add(r);
        } else {
          stack.add(double.tryParse(t) ?? 0.0);
        }
      }
      return stack.isNotEmpty ? stack.last : null;
    } catch (_) {
      return null;
    }
  }

  /// Returns the current number being entered (the last token), or empty string.
  String currentEntry() => _lastNumber();

  String resultString() {
    final res = evaluate();
    if (res == null) return '';
    if (res % 1 == 0) return NumberFormat('#,##0', 'en_US').format(res.toInt());
    return NumberFormat('#,##0.##', 'en_US').format(res);
  }

  bool isDigit(String ch) => ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;
}
