// Verifies a webhook delivery. Run with the raw body, the
// X-Ayinbox-Signature header and the endpoint secret as arguments.
import 'package:ayinbox/ayinbox.dart';

void main(List<String> args) {
  if (args.length != 3) {
    print(
        'usage: dart run examples/verify_webhook.dart <body> <header> <secret>');
    return;
  }
  const webhooks = Webhooks();
  try {
    final event = webhooks.constructEvent(
      payload: args[0],
      header: args[1],
      secret: args[2],
    );
    print('verified ${event['event_type']} ${event['id']}');
  } on SignatureVerificationException catch (error) {
    print('rejected: ${error.message}');
  }
}
