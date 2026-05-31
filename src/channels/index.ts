// Channel self-registration barrel.
// Each import triggers the channel module's registerChannelAdapter() call.
//
// Main ships with one default channel — `cli`, the always-on local-terminal
// channel. Other channel skills (/add-slack, /add-discord, /add-whatsapp,
// ...) copy their module from the `channels` branch and append a
// self-registration import below.

import './cli.js';
import './telegram.js';
import './ios-app.js';

// ios-app v2 transport. Registers under a distinct channel name (`ios-app-v2`)
// so it coexists with the legacy `ios-app` adapter during the migration
// window. The factory is a no-op unless IOS_APP_V2_PORT is set, so unset =
// legacy behavior unchanged.
import { registerIosAppV2 } from './ios-app/v2/index.js';
registerIosAppV2();
