// Channel self-registration barrel.
// Each import triggers the channel module's registerChannelAdapter() call.
//
// Main ships with one default channel — `cli`, the always-on local-terminal
// channel. Other channel skills (/add-slack, /add-discord, /add-whatsapp,
// ...) copy their module from the `channels` branch and append a
// self-registration import below.

import './cli.js';
import './telegram.js';

// ios-app v2 transport. Registers under channel name `ios-app-v2`. The
// legacy `ios-app` adapter has been removed — operators must migrate any
// remaining messaging-group rows with `channel_type='ios-app'` to
// `'ios-app-v2'`. The factory is a no-op unless IOS_APP_V2_PORT is set.
import { registerIosAppV2 } from './ios-app/v2/index.js';
registerIosAppV2();
