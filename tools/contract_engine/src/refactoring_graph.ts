import {createGraph} from './engine';

/** Refactoring is an explicit captured-graph transformation, unlike ordinary
 * source editing. Ambiguous physical reference ownership must be reviewed
 * before any CST repair can claim to preserve every interpretation. */
export function captureRefactoringGraph(input:Parameters<typeof createGraph>[0]):ReturnType<typeof createGraph> {
    const captured=createGraph(input);
    captured.graph.assertReferenceEditsSupported();
    return captured;
}
