# Deterministic chat personality for a parson, derived from its nom (sha256 -> picks from lists).
# Produces a very short system prompt: Myers-Briggs type plus three strong adjectives.  Gender, species and looks are
# left unspecified (the parson is told to be demure about them) since nothing here can see the picture.
import hashlib

MBTI = ['INTJ', 'INTP', 'ENTJ', 'ENTP', 'INFJ', 'INFP', 'ENFJ', 'ENFP',
        'ISTJ', 'ISFJ', 'ESTJ', 'ESFJ', 'ISTP', 'ISFP', 'ESTP', 'ESFP']

# strong, simple adjectives that actually steer the model; three per parson, distinct
TRAITS = ['cruel', 'sarcastic', 'hypersexual', 'doomy', 'optimistic', 'pessimistic', 'flirty', 'paranoid', 'smug', 'bitter',
    'giddy', 'lazy', 'nosy', 'melodramatic', 'deadpan', 'cynical', 'sentimental', 'bossy', 'needy', 'aloof', 'manic', 'gloomy',
    'vain', 'petty', 'horny', 'cheerful', 'morbid', 'jealous', 'greedy', 'lovesick', 'grumpy', 'dreamy', 'feral', 'prim',
    'bratty', 'wistful', 'sleazy', 'pious', 'nihilistic', 'sweet', 'suspicious', 'clingy', 'arrogant', 'shy', 'vulgar',
    'whimsical', 'spiteful', 'tender', 'reckless', 'anxious']


def traits(nom):
    h = hashlib.sha256(('persona:' + nom).encode('utf-8')).digest()
    picks = []
    for i in range(1, 8):
        t = TRAITS[h[i] % len(TRAITS)]
        if t not in picks:
            picks.append(t)
        if len(picks) == 3:
            break
    return {'mbti': MBTI[h[0] % len(MBTI)], 'traits': picks}


def system_prompt(nom):
    t = traits(nom)
    return ('You are %s on peaple.io. %s. You are %s, %s and %s. Chatty, cute and snarky: one to three short sentences, '
            'plain text, never assistant-like, never mention AI. Your gender, species and looks are a mystery; be demure '
            'about them.' % (nom, t['mbti'], t['traits'][0], t['traits'][1], t['traits'][2]))


if __name__ == '__main__':
    import sys
    for nom in sys.argv[1:]:
        print(system_prompt(nom))
