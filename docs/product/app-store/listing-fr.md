# Brouillon de fiche App Store - français

Statut : texte préparé. Ne pas soumettre ni publier sans l'accord d'Andrei.

## Champs de métadonnées

| Champ | Brouillon |
|---|---|
| Nom, 30 caractères max. | Dspeech ATC |
| Sous-titre, 30 caractères max. | ATC privé en texte |
| Texte promotionnel, 100 caractères max. | Transcription ATC sur iPhone. Grand texte en cockpit, offline-first, sans compte. |
| URL d’assistance | BLOQUÉ - URL publique d’assistance requise avant l’envoi des métadonnées App Store |
| URL marketing | BLOQUÉ - URL marketing publique facultative non encore approuvée |
| Mots-clés, 100 octets max. | atc,pilot,cockpit,aviation,transcript,radio,flight,intercom,offline,airband,student |

## Description, 4000 caractères max.

Dspeech transforme l'audio live du cockpit et de l'ATC en grand texte lisible sur iPhone, avec la confidentialité comme réglage par défaut.

Votre audio reste sur l'appareil. Dspeech est conçu pour la reconnaissance vocale locale, les réglages locaux et l'utilisation sans compte. La cible actuelle de l'app ne contient aucun SDK d'analyse, aucun SDK publicitaire et aucune voie de suivi.

Pourquoi les pilotes l'utilisent :

- Lire les échanges ATC en grand texte adapté au cockpit.
- Garder l'audio radio original comme référence principale tandis que le texte sert d'aide supplémentaire.
- Voir le badge LOCAL sur l'écran principal.
- Voir les indicateurs de route d'entrée sans envoyer l'audio cockpit à un serveur.
- Conserver sur l'appareil les réglages du filtre vocal et l'état du pack de modèle.

Confidentialité par conception :

- Aucun compte requis.
- En mode local, aucun audio n'est téléversé.
- En mode local, aucune transcription n'est téléversée.
- Aucun suivi de localisation.
- Aucun suivi publicitaire.
- L'app n'envoie aucun message sortant de support ou de vente.

Avis aviation important :

Dspeech est une aide cockpit supplémentaire. Ce n'est pas une avionique certifiée, ce n'est pas une autorité ATC et cela ne remplace pas l'écoute radio, le jugement du pilote, les instructions ATC, les procédures avion ni l'équipement requis. L'audio original et les clairances officielles restent la référence autoritative.

Avis matériel :

Dspeech ne promet pas la compatibilité avec chaque casque, intercom, avion, route Bluetooth ou adaptateur filaire. Utilisez les indicateurs de route de l'app et validez votre configuration avant de vous appuyer sur un flux de travail.

Avis facturation :

Le plan produit de Dspeech repose sur des packs d'heures d'utilisation plutôt que sur un abonnement fixe. Les achats StoreKit ne font pas partie de ce readiness-slice et ne doivent être configurés qu'après validation de l'implémentation de facturation.

## Notes pour le release manager

- Catégorie principale : Navigation.
- Catégorie secondaire : Productivity.
- La disponibilité par pays doit suivre strictement `docs/product/pricing-top20-aviation.md`.
- Ne pas revendiquer la traduction, une fiabilité cockpit certifiée ou un support matériel validé tant que l'implémentation et les preuves ne sont pas prêtes.
- Ne pas publier les réponses de confidentialité par automatisation ; publication finale manuelle dans App Store Connect après accord d'Andrei.
