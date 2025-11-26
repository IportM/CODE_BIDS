Prise en main
=============

Installation des dépendances
----------------------------

Les scripts Python se trouvent dans le dossier ``scr``. Pour générer la documentation
localement ou sur Read the Docs, créez un environnement virtuel puis installez les
dépendances nécessaires :

.. code-block:: bash

   python -m venv .venv
   source .venv/bin/activate
   pip install -r docs/requirements.txt

Une fois les dépendances installées, la documentation HTML peut être générée avec :

.. code-block:: bash

   cd docs
   make html

Les pages HTML sont produites dans ``docs/_build/html``.

Vérifier les versions de l'environnement
----------------------------------------

La configuration Read the Docs fixe le système sur ``ubuntu-22.04`` avec
Python ``3.11`` et installe Julia via ``apt`` pour les notebooks ou scripts
écrits dans ce langage. Pour contrôler votre environnement local, vous pouvez
utiliser les commandes suivantes :

.. code-block:: bash

   lsb_release -a        # vérifie la version d'Ubuntu
   python --version      # vérifie la version de Python active
   julia --version       # vérifie la version de Julia disponible

En cas d'écart avec les versions épinglées ci-dessus, ajustez votre shell ou
votre configuration (``pyenv``, gestionnaire de versions Julia, etc.) pour
obtenir des résultats cohérents avec la documentation.

Fonctionnalités principales
---------------------------

Les modules Python fournissent plusieurs points d'entrée pour préparer les données :

* ``participants.py`` extrait les informations démographiques depuis les fichiers
  ``subject`` générés par Bruker et produit un fichier ``participants.tsv``
  structuré selon BIDS. L'utilitaire parcourt récursivement plusieurs dossiers
  pour trouver les informations les plus anciennes par participant.
* ``brain_extraction.py`` applique une chaîne de traitement ANTs/ANTsPyNet pour
  extraire le cerveau sur les volumes ``RARE.nii.gz``, en enregistrant toutes les
  étapes intermédiaires dans un sous-dossier ``step`` afin de faciliter le
  contrôle qualité.

Pour plus de détails, consultez la référence automatique des modules ci-dessous.