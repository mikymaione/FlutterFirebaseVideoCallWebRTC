import 'package:flutter/material.dart';

enum TypeOfMsg { ok, info, error }

class SnackMsg {
  static void showOk(BuildContext context, String text) {
    show(context, text, TypeOfMsg.ok);
  }

  static void showInfo(BuildContext context, String text) {
    show(context, text, TypeOfMsg.info);
  }

  static void showError(BuildContext context, String text) {
    show(context, text, TypeOfMsg.error);
  }

  static Color _colorByTypeOfMsg(TypeOfMsg typeOfMsg) {
    switch (typeOfMsg) {
      case TypeOfMsg.ok:
        return const Color(0XFF16F28B);
      case TypeOfMsg.info:
        return const Color(0XFF2493FB);
      case TypeOfMsg.error:
        return const Color(0XFFFF4D4F);
    }
  }

  static void show(BuildContext context, String text, TypeOfMsg typeOfMsg, {SnackBarAction? snackBarAction}) {
    final snackBar = SnackBar(
      backgroundColor: _colorByTypeOfMsg(typeOfMsg),
      content: Row(
        children: [
          if (typeOfMsg == TypeOfMsg.ok) ...[
            const Icon(Icons.done, color: Colors.white),
          ] else if (typeOfMsg == TypeOfMsg.info) ...[
            const Icon(Icons.info_outline, color: Colors.white),
          ] else if (typeOfMsg == TypeOfMsg.error) ...[
            const Icon(Icons.dangerous, color: Colors.white),
          ],
          const SizedBox(width: 20),
          Expanded(
            child: Text(text),
          ),
        ],
      ),
      action: snackBarAction ??
          SnackBarAction(
            label: 'Dismiss',
            textColor: Colors.white,
            onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
          ),
    );

    ScaffoldMessenger.of(context).showSnackBar(snackBar);
  }
}
