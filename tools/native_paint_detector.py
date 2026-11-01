"""Stable native text-state matching; independent of GTK and source colors."""
# Templates identify the repeating inserted/deleted text states. Only pixels
# stable in every warmup observation and different between A and B are used.
# Caret blink, checking labels and unrelated damage cannot satisfy this mask.
def templates(states, stability=None, ignored=()):
    a, b = states[0][0], states[1][0]
    channels = states[0][1]
    mask = []
    ignored = set(ignored)
    for i in range(0, len(a), channels):
        if i//channels in ignored:
            continue
        aa, bb = a[i:i+3], b[i:i+3]
        if aa == bb:
            continue
        if all(v[0][i:i+3] == (aa if j%2==0 else bb)
               for j,v in enumerate(states)) and (stability is None or
                all(v[0][i:i+3] == (aa if j%2==0 else bb)
                    for j,v in enumerate(stability))):
            mask.extend(range(i,i+3))
    if len(mask) < 36:
        raise RuntimeError('Crop lacks stable changed text pixels; recalibrate its geometry')
    return mask, bytes(a[i] for i in mask), bytes(b[i] for i in mask)

def matches(image, template, state):
    mask, a, b = template
    return bytes(image[0][i] for i in mask) == (a if state == 0 else b)

