# S/R Grid Bot System for MetaTrader 5

A two-part system for placing automated limit orders at manually defined support and resistance zones in MetaTrader 5.

## How It Works

### Zone Server (Node.js)
A local Express server that stores and serves S/R zone data. It exposes a simple REST API that the MT5 Expert Advisor polls on a schedule. A built-in web GUI lets you define zones per symbol — specifying direction (buy/sell), strength (strong/regular), and whether the zone is a single price point or a price range.

### ZoneRaider EA (MetaTrader 5)
An Expert Advisor that runs on a chart in MT5 and periodically fetches active zones from the local server. For each zone, it calculates an entry price and places a limit order. Position sizing is ATR-based, and the EA enforces a configurable daily risk budget and maximum number of simultaneous positions. All orders are automatically closed and the session is reset at a configurable end-of-day hour.

## Key Features

- Web GUI for fast zone entry across multiple symbols
- Supports point entries and ranged zones
- ATR-based position sizing
- Daily risk budget cap
- Configurable NY session open and end-of-day close times
- Weekend polling suppression
- Zones are cleared server-side after market hours
