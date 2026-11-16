---
title: "Privacy · ModeDock"
description: "Wat de optionele, anonieme gebruiksgegevens van ModeDock bevatten, wat nooit wordt verzameld en hoe je het uitzet."
---

# Privacy

ModeDock werkt zonder iets te versturen. Als je instemt, verstuurt het anonieme tellingen van de functies die je gebruikt. Daaruit leer ik wat beter kan.

## Uit tot je ja zegt

Bij de eerste start vraagt ModeDock: _Anonieme gebruiksgegevens delen?_ Er wordt niets verstuurd tenzij je Delen kiest. Je kunt dit altijd wijzigen in Instellingen → Algemeen.

## Wat wordt verstuurd

Ongeveer elke 8 uur, en alleen als er iets is geteld:

- Hoe vaak je elke functie gebruikte, zoals het paneel openen of de helderheid wijzigen. Alleen het aantal, nooit wat er op het scherm stond.
- Hoe ModeDock is ingesteld, zoals hoeveel profielen en externe schermen je hebt. Nooit hun namen.
- De versie van de app en macOS, de taal van de app en of de Mac Apple silicon of Intel heeft.
- Een willekeurig installatie-ID. Het wordt gemaakt als je instemt en verwijderd als je stopt met delen, en het is niet gekoppeld aan jou, je Mac of je Apple-account.

Gebruik Toon gegevens… in Instellingen → Algemeen om een rapport precies zo te zien als het wordt verstuurd.

## Wat de server toevoegt

De dag waarop het rapport binnenkwam en je land. Cloudflare, dat de server draait, zoekt het land op. De server leest of bewaart je IP-adres niet, en de logs staan uit.

## Wat nooit wordt verzameld

- Je naam, e-mailadres, Apple-account of iets wat je typt
- IP-adressen, serienummers of andere hardware-ID's
- Namen van schermen, profielen of bestanden, en de inhoud van bestanden
- Schermafbeeldingen of iets op je schermen

## Waar het wordt bewaard

In een Cloudflare-database in de Europese Unie, via `telemetry.modedock.app`. Alleen de beheerder van ModeDock kan het lezen.

## Wat openbaar wordt gemaakt

De startpagina toont totalen over de afgelopen 30 dagen: actieve installaties, de meest gebruikte functies, macOS-versies en landen. Elk getal omvat minstens 5 installaties, zodat niemand eruit te pikken is. Installatie-ID's en losse rapporten worden nooit gepubliceerd.

## Het uitzetten

Schakel Deel anonieme gebruiksstatistieken uit in Instellingen → Algemeen. ModeDock stopt met versturen en verwijdert zijn installatie-ID en tellingen. Zet je het weer aan, dan krijg je een nieuw installatie-ID.

Wil je al verstuurde rapporten laten verwijderen, open dan een issue op [GitHub](https://github.com/ilijamt/modedock/issues) met het installatie-ID uit Toon gegevens…, voordat je het delen uitzet.

## Controleren op updates

Ongeveer één keer per dag vraagt ModeDock aan GitHub, waar de releases staan, of er een nieuwe
versie is. Daarbij wordt alleen de versie van de app meegestuurd. Je zet het uit via Instellingen → Algemeen →
Updates.

## De code

De app en de server zijn allebei open source: zie [Telemetry.swift](https://github.com/ilijamt/modedock/blob/main/Packages/ModeDockKit/Sources/ModeDockCore/Telemetry.swift) en [server/telemetry](https://github.com/ilijamt/modedock/tree/main/server/telemetry).

Laatst bijgewerkt op 15 november 2026.
