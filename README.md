# Brockman
Read your favourite RSS feeds in your favourite IRC channels

## Usage

### Configuration
In case you don't want to (or cannot) use the provided NixOS module, you can always simply execute `brockman PATH/TO/CONFIG.json` to fire up an instance of Brockman with a specified config.
For a fully fledged config, look at [the example](./config/example.json).

- `channel` specifies the channel all bots should join and post to.
- `shortener` (optional) specifies an endpoint that returns shortened URLs when they are POSTed to it.
- `pastebin` (optional) specifies an endpoint that returns a link when you POST content to it.
- `defaultDelay` (optional) specifies the amount of seconds to wait before fetching each feed again. This is only used when `bot.NAME.delay` isn't set for a specific feed and when Brockman cannot figure out an adequate interval by itself.
- `maxStartDelay` (optional, default `60`) is used for Brockman's startup sequence: if you have many—say, a thousand—bots and start them all at once, you won't get an even stream of news in your channels. Therefore, a bot's startup will be delayed by a random number of seconds. This field specifies the maximum.
- `fetchConcurrency` (optional, default `64`) is the number of feeds fetched at the same time across all bots. Each fetch holds its feed in memory while it is parsed; feeds over 32 MiB are rejected ("Feed too large").
- `notifyErrors` (optional, default `true`) specifies whether to notify (IRC notice) of errors that happen when fetching feeds, e. g. 404 errors etc.
- `noPrivmsg` (optional, default `false`) specifies whether to send the feed items as `NOTICE` instead of `PRIVMSG`.
- `statePath` (optional, default `$HOME/brockman.json`) specifies the path of Brockman's state file.
- `irc.host` specifies the IRC server to connect to.
- `irc.port` (optional, default `6667`) specifies the port of that IRC server.
- `irc.tls` (optional, default `false`) specifies whether the IRC connection should be made using TLS.
- `irc.oper.name` and `irc.oper.passwordFile` (optional) make the controller send `OPER` with that name and the password read from that file after connecting. Relay mode needs this on ergo for the `relaymsg` capability (and `nofakelag` at high message rates).
- `relaySuffix` (optional) enables relay mode: reporter bots open no IRC connection of their own. The controller (which is then required) posts their items into channels with `RELAYMSG CHANNEL NAME<relaySuffix>`, sends their error notices itself as `[NAME<relaySuffix>] …`, and messages subscribed users as `<NAME<relaySuffix>> …`. The suffix must contain one of the IRC server's relaymsg separators (ergo default: `/`), e. g. `/rss`. This lets one brockman serve tens of thousands of feeds over a single connection; it needs an IRC server with `RELAYMSG` (ergo).
- `controller.nick` when set, enables the controller-bot feature: A bot with the specified nick will join the channel specified in `channel` (alongside the channels specified in `controller.extraChannels`). For more information on how to interact with that bot, see [below](#controller).
- `controller.extraChannels` (optional, default `[]`): see above.
- `bots.NAME.feed` initializes a bot named `NAME` with a feed. That bot will automatically join the channel specified in `channel` and post updates there.
- `bots.NAME.delay` (optional) overrides the interval with which the bot checks its feed. This is figured out intelligently if you don't specify a value.
- `bots.NAME.extraChannels` (optional, default `[]`) specifies additional channels, to which the bot posts its messages.

### Interacting with Brockman
Brockman keeps track of its state using a state file that has the same format as the config specified above. While Brockman is running, you can interactively modify its state, e. g. move bots to different channels, override their delays, add new bots. That modified state is regularly written to the specified `statePath`. On startup, Brockman will try to resume from `statePath` if it finds a valid config there.

#### Reporter Bots
Reporter bots (those specified under the `bots` key) can be `/invite`d to and `/kick`ed from channels they are in. On an `/invite NAME` from a channel, that channel will be added to the bot's `extraChannels` and the bot will join said channel. On `/kick NAME`, the current channel name will be removed from the bot's `extraChannels`.

#### Controller
The controller bot can be used to add (`CONTROLLERNAME: add BOTNAME FEEDURL`) reporter bots.

In relay mode, reporter bots are not IRC clients, so the controller also handles their commands: `CONTROLLERNAME: remove BOTNAME`, `info BOTNAME`, `tick BOTNAME SECONDS` (anything but a number: automatic), `set-url BOTNAME FEEDURL`, `subscribe BOTNAME` / `unsubscribe BOTNAME` (private messages from that bot), and, said in a channel, `invite BOTNAME` / `kick BOTNAME` to add or remove that channel from the bot's `extraChannels`. `BOTNAME` may be given with or without the relay suffix. Without relay mode these are `/msg BOTNAME …`, `/invite` and `/kick` on the bots themselves (see `CONTROLLERNAME: help`).

If a `pastebin` is set, `CONTROLLERNAME: dump` will publish the current state online, making it easy for you to fork a running brockman instance.

Like the reporter bots, the controller bot can be `/invite`d and `/kick`ed and will adjust its `extraChannels` value accordingly.

## Development

### Development REPL
Run `nix develop -c $SHELL` to bring the package's dependencies into scope.
Then you can run `cabal repl` to enter a REPL with the Haskell modules in scope.

### Build
Run `nix build`.

### Test
Run `nix build .#vm --impure` to build a test VM which you can run using `result/bin/run-nixos-vm`.
The test VM will be running an IRC server together with a `brockman` instance with one RSS feed, which will post to the `#news` channel.

## Eponym

![Kent Brockman](https://vignette.wikia.nocookie.net/simpsons/images/5/52/Kent_Brockman_2.png/revision/latest?cb=20121228104403&path-prefix=it)
