# Y99

An unofficial native iOS (SwiftUI) client for the y99 / meetyou.me chat site.

## Features
- Friends list with online status; private chats with sent / delivered / read status
- Photos (camera and library) and videos (`.mov` rewrapped as `.mp4`; WebM plays via WebKit)
- y99's custom emoji (animated blobs, GIFs) with a recently-used row
- Push notifications without a paid Apple account, through the **Y99 Alerts** Home Screen web app
  (Web Push; see `Sources/PushRelay.swift`)

## Build
Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
```
cp Secrets.example.swift Sources/Secrets.swift   # then fill it in
xcodegen generate
open Y99.xcodeproj   # set your own signing team, pick a device, Run
```
Optional: put y99's blob emoji originals in `Blobs/<name>.webp` to bundle them; without them the app
downloads the emoji from y99 at runtime. With a free (personal) Apple team the app must be reinstalled every 7 days.

## Sign-in
There is no programmatic login. `LoginView` loads the site in a `WKWebView`; after you sign in there,
the app reads the site's saved session and uses its `auth` token for API calls.

This project is not affiliated with y99 or meetyou.me.
