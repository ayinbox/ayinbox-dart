// Lists every campaign in the workspace. Reads AYINBOX_API_KEY.
import 'package:ayinbox/ayinbox.dart';

Future<void> main() async {
  final client = AyInbox();
  try {
    await for (final campaign in client.campaigns.listAll(limit: 50)) {
      print('${campaign.id}  ${campaign.status}  ${campaign.name}');
    }
  } on ApiException catch (error) {
    print('API error ${error.status} ${error.code}: ${error.message}');
  } finally {
    client.close();
  }
}
