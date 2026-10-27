# Beispiel: delivery window in der Orders API

Reference transcript of the LokalBot sample meeting: what each synthetic voice was asked to say, with the time each turn starts in the recording. The people and the company are fictional.

**[00:00] Maya:** Das ist die Beispielbesprechung von LokalBot. Die Stimmen sind synthetisch, und die Firma und die Personen darin sind erfunden.

**[00:07] Maya:** Hallo Daniel. Hörst du mich gut?

**[00:10] Daniel:** Laut und deutlich, Maya. Sorry, dass ich eine Minute zu spät bin, mein Build lief noch.

**[00:15] Maya:** Kein Problem. Lass uns das delivery window für die Orders API klären.

**[00:21] Daniel:** Klar. Kurz zum Hintergrund: Der Support möchte, dass Kunden ein delivery window sehen, also zum Beispiel zwischen zwei und vier Uhr nachmittags, statt der einen ETA-Uhrzeit, die wir heute zurückgeben.

**[00:35] Maya:** Genau. Und Priya aus dem Partner-Success-Team sagt, dass drei unserer größten Partner genau das Gleiche angefragt haben.

**[00:42] Maya:** Also, der Plan von letzter Woche: Wir ersetzen das Feld ETA durch ein neues Objekt delivery window und bringen das als Version drei der API raus.

**[00:54] Daniel:** So war der Plan. Das Fenster wären zwei Zeitstempel, ein Anfang und ein Ende, beide in UTC. Version drei kann ich bis zum achtzehnten November fertig haben.

**[01:06] Maya:** Okay. Entscheidung für jetzt: Version drei, das delivery window ersetzt ETA, und unser Ziel ist der achtzehnte November.

**[01:16] Daniel:** Von der Performance her geht beides. Ich hab's gestern gemessen, die P95-Latenz bleibt bei etwa hundertachtzig Millisekunden.

**[01:25] Maya:** Gut. Und was ist mit der mobilen App?

**[01:28] Daniel:** Tomás sagt, das Mobile-Team kann es in Release vier Punkt zwei mitnehmen, aber nicht früher.

**[01:35] Maya:** Das passt. Und das Testen?

**[01:38] Daniel:** Lena schreibt Contract-Tests. Sie braucht zwei Tage, sobald das Schema eingefroren ist.

**[01:45] Daniel:** Moment, bevor wir das festzurren. Ich bin gestern Abend die Partner-Integrationen durchgegangen. Zweiundvierzig Partner rufen den Orders-Endpunkt auf, und neunzehn davon nutzen generierte Clients, die abbrechen, wenn ein erwartetes Feld fehlt. Wenn wir ETA entfernen, gehen diese neunzehn am Tag des Releases kaputt.

**[02:05] Maya:** Neunzehn von zweiundvierzig. Das ist fast die Hälfte. Und eine Version drei heißt, dass wirklich jeder einzelne Partner migrieren muss.

**[02:13] Daniel:** Genau. Allein Fernhill hat vier Monate gebraucht, um auf Version zwei umzusteigen.

**[02:19] Maya:** Dann ändern wir die Entscheidung. Keine Version drei. Die Antwort bleibt abwärtskompatibel: ETA bleibt genau so, wie es ist, und das delivery window kommt als neues, optionales Feld dazu. Wenn wir das Fenster nicht kennen, lassen wir das Feld weg.

**[02:33] Daniel:** Optional, weggelassen, wenn es unbekannt ist, ETA unverändert, und wir bleiben auf Version zwei. Das ist auch weniger Arbeit. Ich kann es bis zum elften November ausliefern statt bis zum achtzehnten.

**[02:49] Maya:** Super. Also, fürs Protokoll: Das ersetzt, was wir am Anfang gesagt haben. Die Antwort bleibt abwärtskompatibel, das delivery window ist optional, und wir liefern am elften November aus.

**[03:01] Daniel:** Soll ich Lena dann sagen, dass das Schema eingefroren ist?

**[03:05] Maya:** Ja, mach das. Und Priya schreibt den drei Partnern, die danach gefragt haben, eine E-Mail. Daniel, kannst du die API-Spezifikation und das Changelog aktualisieren?

**[03:16] Daniel:** Ja, beides ist bis Freitag erledigt.

**[03:18] Daniel:** Eine Sache haben wir noch nicht geklärt: Machen wir einen Backfill der delivery windows für Bestellungen, die vor der Änderung angelegt wurden, oder nur für neue Bestellungen?

**[03:28] Maya:** Hm. Ein Backfill heißt, den Schätzer für rund zwei Millionen offene Bestellungen noch mal laufen zu lassen. Ehrlich gesagt weiß ich nicht, ob sich das lohnt.

**[03:37] Daniel:** Ich auch nicht. Es hängt davon ab, ob Partner sich alte Bestellungen überhaupt ansehen.

**[03:43] Maya:** Lassen wir das erst mal offen. Ich frage Priya, ob die Partner das für alte Bestellungen brauchen.

**[03:49] Daniel:** Okay. Der Backfill ist also noch offen.

**[03:53] Maya:** Ja. Danke, Daniel. Das war's für heute.

