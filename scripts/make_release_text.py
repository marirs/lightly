#!/usr/bin/env python3
"""Release text for both apps from the website's legal pages (single source):
  /Users/sg/Documents/Dev/pub-sites/lightly/public/{privacy,terms}.md  ->  ios/Lightly/Resources/Content/legal.json (schema 1)
                                                                       ->  android/app/src/main/assets/legal/release-text.json
Only site decoration is dropped (the "Source:" line, page labels, the display tagline, the section index, link markup);
the wording of every section is copied unchanged. Support destination: https://lightly.pro/support.
These are the website's drafts as of their "Last updated" date, not legal approval (docs/v1/release/README.md)."""
import json, os, re, sys
SITE = os.environ.get('LIGHTLY_SITE', '/Users/sg/Documents/Dev/pub-sites/lightly/public')
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SUPPORT = 'https://lightly.pro/support'

def sections(path):
    text = open(path, encoding='utf-8').read()
    # Body sections start after the in-page index line ("[Scope](#section-0)…").
    body = text[text.index('(#section-0)'):]
    body = body[body.index('\n'):]
    out = []
    for block in re.split(r'^## ', body, flags=re.M)[1:]:
        heading, _, rest = block.partition('\n')
        paragraphs = [re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', p.strip()) for p in rest.strip().split('\n\n') if p.strip()]
        out.append({'heading': heading.strip(), 'paragraphs': paragraphs})
    return out

privacy, terms = sections(os.path.join(SITE, 'privacy.md')), sections(os.path.join(SITE, 'terms.md'))
ios = {'schemaVersion': 1, 'privacyPolicy': {'sections': privacy}, 'termsOfUse': {'sections': terms}, 'support': {'url': SUPPORT}}
android = {'privacyPolicy': {'sections': [{'heading': s['heading'], 'body': '\n\n'.join(s['paragraphs'])} for s in privacy]},
           'termsOfUse': {'sections': [{'heading': s['heading'], 'body': '\n\n'.join(s['paragraphs'])} for s in terms]},
           'supportDestination': SUPPORT}
for path, data in ((os.path.join(REPO, 'ios/Lightly/Resources/Content/legal.json'), ios),
                   (os.path.join(REPO, 'android/app/src/main/assets/legal/release-text.json'), android)):
    with open(path, 'w', encoding='utf-8') as f: json.dump(data, f, ensure_ascii=False, indent=1); f.write('\n')
    print(path, sum(len(s['paragraphs']) if 'paragraphs' in s else 1 for d in (data.get('privacyPolicy'), data.get('termsOfUse')) for s in d['sections']), 'paragraph blocks')
for s in privacy + terms: print('-', s['heading'], '|', s['paragraphs'][0][:70])
