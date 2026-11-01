/** Explicit pinned APIs supplied by the isolated policy environment, not
 * ambient/project node_modules lookup. They are disclosed in review bindings. */
export const policyBuiltinModules:Readonly<Record<string,{target:string;version:string}>>=Object.freeze({
    '@stoplight/spectral-core':Object.freeze({target:'busyapi:policy-module/spectral-core',version:'1.24.0'}),
    '@stoplight/spectral-functions':Object.freeze({target:'busyapi:policy-module/spectral-functions',version:'1.11.0'}),
    '@stoplight/spectral-formats':Object.freeze({target:'busyapi:policy-module/spectral-formats',version:'1.9.0'}),
    '@stoplight/spectral-rulesets':Object.freeze({target:'busyapi:policy-module/spectral-rulesets',version:'1.23.0'}),
});
