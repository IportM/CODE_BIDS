import os
import sys
from datetime import datetime

# Ajout du dossier contenant les scripts pour permettre l'autodocumentation
sys.path.insert(0, os.path.abspath(os.path.join('..', 'scr')))

project = 'CODE_BIDS'
author = 'CODE_BIDS Contributors'
release = datetime.today().strftime('%Y.%m.%d')

extensions = [
    'sphinx.ext.autodoc',
    'sphinx.ext.autosectionlabel',
    'sphinx.ext.napoleon',
    'sphinx.ext.viewcode',
]

autosectionlabel_prefix_document = True

# Modules lourds ou optionnels ignorés pendant la génération de la documentation
autodoc_mock_imports = ['ants', 'antspynet']
master_doc = 'index'
templates_path = ['_templates']
exclude_patterns = ['_build', 'Thumbs.db', '.DS_Store']

language = 'fr'

html_theme = 'sphinx_rtd_theme'
html_static_path = ['_static']