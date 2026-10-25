import 'package:fetch_client/fetch_client.dart';
import 'package:http/http.dart' as http;

/// CORS mode: the agent service is another origin (FetchClient defaults to
/// no-cors, whose responses cannot be read).
http.Client createStreamingClient() => FetchClient(mode: RequestMode.cors);
