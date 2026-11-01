// Development-only reader of actual visible, lazy controls. No production
// parser, resolver or renderer extension is defined by this test utility.
import assert from 'node:assert/strict';
export async function readAuthoredPanels(page) {
  const seen=new Set(),definitions=new Set();
  let steps=0;
  for(;steps<128;steps++){
    await page.waitForFunction(()=>{
      const branches=[...document.querySelectorAll('[data-busyapi-authored-branch]')];
      for(const branch of branches)if(!branch.open)branch.open=true;
      return branches.every(branch=>[...branch.querySelectorAll('[data-busyapi-authored-content]')].some(node=>node.getAttribute('data-busyapi-authored-content')===branch.getAttribute('data-busyapi-authored-branch')));
    });
    seen.add(await page.locator('body').innerText());
    const opened=await page.evaluate(visited=>{
      for(const button of document.querySelectorAll('[data-busyapi-definition]')){
        const target=button.getAttribute('data-busyapi-definition');
        if(button.isConnected&&button.getClientRects().length&&getComputedStyle(button).visibility!=='hidden'&&!visited.includes(target)){
          window.busyapiPanelWait={panel:button.closest('[data-busyapi-authored-panel]'),target};button.click();return target;
        }
      }
    },[...definitions]);
    if(opened){
      definitions.add(opened);
      await page.waitForFunction(()=>{
        const {panel,target}=busyapiPanelWait;
        return panel?.isConnected&&panel.querySelector(':scope > [data-busyapi-authored-content]')?.getAttribute('data-busyapi-authored-content')===target;
      });
      continue;
    }
    const returned=await page.evaluate(()=>{
      const button=[...document.querySelectorAll('button')].find(node=>node.getClientRects().length&&getComputedStyle(node).visibility!=='hidden'&&node.textContent.startsWith('← '));
      if(!button)return false;
      const panel=button.closest('[data-busyapi-authored-panel]');
      window.busyapiPanelWait={panel,target:panel?.getAttribute('data-busyapi-authored-panel')};button.click();return true;
    });
    if(!returned)break;
    await page.waitForFunction(()=>{
      const {panel,target}=busyapiPanelWait;
      return panel?.isConnected&&panel.querySelector(':scope > [data-busyapi-authored-content]')?.getAttribute('data-busyapi-authored-content')===target;
    });
  }
  assert(steps<128,'The visible authored-panel walk exceeded its bounded review budget');
  return [...seen].join('\n');
}
