# Vendored Qt 6.9.2 QtPositioning QML import

Sibling of `../QtLocation/SOURCE.md` — same rev, same rationale. See
README → "Vendored Qt imports".

QtPositioning is required only because `Map.center` is a
`QGeoCoordinate` constructed via `QtPositioning.coordinate(lat, lon)`.
No GPS / IP geolocation lookup is performed at runtime; the
`PositionSource` element is not used.
