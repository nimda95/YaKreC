import '../log/logger.dart';
import '../models/device.dart';
import 'base.dart';
import 'nanokvm/client.dart';
import 'pikvm/client.dart';

DeviceClient buildClient(Device d, Logger logger) {
  switch (d.type) {
    case DeviceType.pikvm:
      return PiKvmClient(d, logger);
    case DeviceType.nanokvm:
      return NanoKvmClient(d, logger);
  }
}
