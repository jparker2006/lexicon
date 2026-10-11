# Lexicon's own file, not upstream: upstream's __init__.py also imports
# model_ids.py, which the scorer does not need. normalizer.py and
# english_abbreviations.py are byte-identical to upstream (see VENDORED.md).
from .normalizer import EnglishTextNormalizer

__all__ = ["EnglishTextNormalizer"]
