#!/usr/bin/env python
# -*- coding: utf-8 -*- #

from __future__ import unicode_literals
from os import environ


SITENAME = u"Jan's Blog"
AUTHOR = u'Jan Hendrik Metzen'
TAGLINE = u''
SITEURL = 'http://localhost:8000'
FEED_DOMAIN = SITEURL
FEED_ATOM = 'feeds/all.atom.xml'
FEED_RSS = 'feeds/all.rss'
TIMEZONE = 'Europe/Berlin'
DEFAULT_LANG = u'en'
DATE_FORMATS = {
    'en': '%Y-%m-%d',
}
DEFAULT_PAGINATION = 1

THEME = 'themes/bootstrap2'


# display items
LOGO_URL = 'https://dl.dropboxusercontent.com/u/7030113/www/art-noveau-ornament.png'
MENUITEMS = (
    ('archives', '/archives.html'),
)
DISPLAY_PAGES_ON_MENU = True
FOOTER_MESSAGE = u'This work is licensed under the <a href="http://creativecommons.org/licenses/by-sa/3.0/" rel="license">CC BY-SA</a>.'
#TWITTER_USERNAME = u'kfr_2'


#STATIC_PATHS = ()
FILES_TO_COPY = (
    ('extra/README', 'README'),
    ('extra/LICENSE', 'LICENSE'),
    ('extra/humans.txt', 'humans.txt'),
    ('extra/favicon.ico', 'favicon.ico'),
    ('extra/404.html', '404.html'),
)

# Plugins and their settings.
#PLUGIN_PATH = 'pelican-plugins'
#PLUGINS = ['sitemap']

GITHUB_USERNAME = 'jmetzen'
#GITHUB_AUTH_TOKEN = environ.get('GITHUB_AUTH_TOKEN')
#if GITHUB_AUTH_TOKEN is None:
#    raise NotImplementedError("You should define GITHUB_AUTH_TOKEN in your OS's environment.")

SITEMAP = {
    'format': 'xml',
    'priorities': {
        'articles': 0.5,
        'indexes': 0.5,
        'pages': 0.5
    },
    'changefreqs': {
        'articles': 'weekly',
        'indexes': 'weekly',
        'pages': 'monthly'
    }
}

