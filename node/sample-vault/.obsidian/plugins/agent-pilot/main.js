var b=Object.defineProperty;var D=Object.getOwnPropertyDescriptor;var C=Object.getOwnPropertyNames;var $=Object.prototype.hasOwnProperty;var L=(d,s)=>{for(var t in s)b(d,t,{get:s[t],enumerable:!0})},q=(d,s,t,e)=>{if(s&&typeof s=="object"||typeof s=="function")for(let n of C(s))!$.call(d,n)&&n!==t&&b(d,n,{get:()=>s[n],enumerable:!(e=D(s,n))||e.enumerable});return d};var R=d=>q(b({},"__esModule",{value:!0}),d);var I={};L(I,{default:()=>f});module.exports=R(I);var r=require("obsidian"),B={orchestratorUrl:"http://localhost:3333",showAgentBadges:!0,autoRefreshQueue:!0,refreshInterval:3e3},v="agent-pilot-view",y=class extends r.ItemView{constructor(t,e){super(t);this.currentTab="chat";this.messages=[];this.currentAgent=null;this.queueState={running:[],completed:[],pending:[]};this.agents=[];this.refreshTimer=null;this.plugin=e}getViewType(){return v}getDisplayText(){return"Agent Pilot"}getIcon(){return"bot"}async onOpen(){this.containerEl=this.contentEl,this.containerEl.empty(),this.containerEl.addClass("agent-pilot-view"),this.addStyles(),this.render(),this.plugin.settings.autoRefreshQueue&&this.startAutoRefresh(),await this.loadAgents(),await this.refreshQueue()}async onClose(){this.stopAutoRefresh()}startAutoRefresh(){this.refreshTimer=window.setInterval(()=>{this.refreshQueue()},this.plugin.settings.refreshInterval)}stopAutoRefresh(){this.refreshTimer&&(window.clearInterval(this.refreshTimer),this.refreshTimer=null)}render(){this.containerEl.empty();let e=this.containerEl.createDiv({cls:"pilot-header"}).createDiv({cls:"pilot-tabs"});this.createTab(e,"chat","Chat"),this.createTab(e,"agents","Agents"),this.createTab(e,"activity","Activity");let n=this.containerEl.createDiv({cls:"pilot-content"});switch(this.currentTab){case"chat":this.renderChatTab(n);break;case"agents":this.renderAgentsTab(n);break;case"activity":this.renderActivityTab(n);break}}createTab(t,e,n){let a=t.createEl("button",{cls:`pilot-tab ${this.currentTab===e?"active":""}`,text:n});e==="activity"&&this.queueState.running.length>0&&a.createEl("span",{cls:"pilot-badge",text:String(this.queueState.running.length)}),a.addEventListener("click",()=>{this.currentTab=e,this.render()})}renderChatTab(t){let e=t.createDiv({cls:"pilot-selector-row"});e.createEl("span",{text:"Agent:",cls:"pilot-label"});let n=e.createEl("select",{cls:"pilot-select"});n.createEl("option",{value:"",text:"Vault Agent (default)"});for(let g of this.agents){let m=n.createEl("option",{value:g.path,text:g.name});g.path===this.currentAgent&&(m.selected=!0)}n.addEventListener("change",()=>{this.currentAgent=n.value||null,this.addSystemMessage(`Switched to ${n.value||"Vault Agent"}`)}),e.createEl("button",{text:"Clear",cls:"pilot-btn-small"}).addEventListener("click",async()=>{await this.clearSession()});let o=t.createDiv({cls:"pilot-messages"});if(this.messages.length===0)o.createDiv({cls:"pilot-empty",text:"Start a conversation with your vault agents"});else for(let g of this.messages){let m=o.createDiv({cls:`pilot-message pilot-message-${g.role}`});g.agentPath&&m.createEl("div",{cls:"pilot-message-agent",text:g.agentPath.replace("agents/","").replace(".md","")}),m.createEl("div",{cls:"pilot-message-content",text:g.content}),m.createEl("div",{cls:"pilot-message-time",text:g.timestamp.toLocaleTimeString()})}setTimeout(()=>{o.scrollTop=o.scrollHeight},10);let c=t.createDiv({cls:"pilot-input-area"}),i=c.createEl("textarea",{cls:"pilot-input",attr:{placeholder:"Ask your agents anything..."}});i.addEventListener("keydown",async g=>{g.key==="Enter"&&!g.shiftKey&&(g.preventDefault(),await this.sendMessage(i.value),i.value="")}),c.createEl("button",{text:"Send",cls:"pilot-send"}).addEventListener("click",async()=>{await this.sendMessage(i.value),i.value=""})}addSystemMessage(t){this.messages.push({role:"system",content:t,timestamp:new Date}),this.render()}async sendMessage(t){var n;if(!t.trim())return;this.messages.push({role:"user",content:t,timestamp:new Date}),this.render();let e=this.app.workspace.getActiveFile();try{let o=await(await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({message:t,agentPath:this.currentAgent,documentPath:e==null?void 0:e.path})})).json();this.messages.push({role:"assistant",content:o.response||o.error||"No response",timestamp:new Date,agentPath:o.agentPath}),((n=o.spawned)==null?void 0:n.length)>0&&this.addSystemMessage(`Spawned ${o.spawned.length} sub-agent(s)`)}catch(a){this.messages.push({role:"system",content:`Error: ${a.message}`,timestamp:new Date})}this.render()}async clearSession(){try{await fetch(`${this.plugin.settings.orchestratorUrl}/api/chat/session?agentPath=${this.currentAgent||""}`,{method:"DELETE"}),this.messages=[],this.addSystemMessage("Session cleared")}catch(t){new r.Notice(`Error: ${t.message}`)}}renderAgentsTab(t){let e=t.createDiv({cls:"pilot-section-header"});if(e.createEl("h3",{text:"Available Agents"}),e.createEl("button",{text:"Refresh",cls:"pilot-btn-small"}).addEventListener("click",()=>this.loadAgents()),this.agents.length===0){t.createDiv({cls:"pilot-empty",text:"No agents found in vault"});return}let a=this.agents.filter(i=>i.type==="doc"),o=this.agents.filter(i=>i.type==="standalone"),c=this.agents.filter(i=>i.type==="chatbot"||!i.type);if(a.length>0){let i=t.createDiv({cls:"pilot-agent-section"});i.createEl("h4",{text:"Document Agents",cls:"pilot-section-title"}),i.createEl("p",{text:"Run on the current document",cls:"pilot-section-hint"});for(let l of a)this.renderAgentCard(i,l,"doc")}if(o.length>0){let i=t.createDiv({cls:"pilot-agent-section"});i.createEl("h4",{text:"Standalone Agents",cls:"pilot-section-title"}),i.createEl("p",{text:"Run independently",cls:"pilot-section-hint"});for(let l of o)this.renderAgentCard(i,l,"standalone")}if(c.length>0){let i=t.createDiv({cls:"pilot-agent-section"});i.createEl("h4",{text:"Chatbot Agents",cls:"pilot-section-title"}),i.createEl("p",{text:"Interactive conversation",cls:"pilot-section-hint"});for(let l of c)this.renderAgentCard(i,l,"chatbot")}}renderAgentCard(t,e,n){var l;let a=t.createDiv({cls:"pilot-agent-card"}),o=a.createDiv({cls:"pilot-agent-header"});o.createEl("span",{text:e.name,cls:"pilot-agent-name"});let c=o.createEl("span",{cls:`pilot-type-badge pilot-type-${n}`,text:n});a.createEl("div",{cls:"pilot-agent-desc",text:((l=e.description)==null?void 0:l.substring(0,100))||"No description"});let i=a.createDiv({cls:"pilot-agent-actions"});switch(n){case"doc":i.createEl("button",{text:"Run on Current Doc",cls:"pilot-btn-primary"}).addEventListener("click",()=>this.runDocAgent(e.path));break;case"standalone":i.createEl("button",{text:"Run",cls:"pilot-btn-primary"}).addEventListener("click",()=>this.spawnAgent(e.path));break;case"chatbot":default:i.createEl("button",{text:"Chat",cls:"pilot-btn-primary"}).addEventListener("click",()=>{this.currentAgent=e.path,this.currentTab="chat",this.addSystemMessage(`Now chatting with ${e.name}`)});break}}startFollowUp(t){var n,a;this.currentAgent=t.agentPath;let e=`Previous run on ${t.agentPath.replace("agents/","").replace(".md","")}`;(n=t.context)!=null&&n.documentPath&&(e+=` for document: ${t.context.documentPath}`),this.messages=[],this.messages.push({role:"system",content:e,timestamp:new Date}),(a=t.result)!=null&&a.response&&this.messages.push({role:"assistant",content:t.result.response,timestamp:new Date(t.completedAt||Date.now()),agentPath:t.agentPath}),this.currentTab="chat",this.render(),new r.Notice("Ready to follow up - type your message below")}async runDocAgent(t){let e=this.app.workspace.getActiveFile();if(!e||!e.path.endsWith(".md")){new r.Notice("Please open a markdown file first");return}try{let a=await(await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents/spawn`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agentPath:t,message:"Process this document.",context:{documentPath:e.path}})})).json();a.error?new r.Notice(`Error: ${a.error}`):(new r.Notice(`Running ${t.replace("agents/","").replace(".md","")} on ${e.name}`),this.currentTab="activity",await this.refreshQueue())}catch(n){new r.Notice(`Error: ${n.message}`)}}async loadAgents(){try{let t=await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents`);this.agents=await t.json(),this.currentTab==="agents"&&this.render()}catch(t){console.error("Failed to load agents:",t)}}async spawnAgent(t){var e;try{let a=await(await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents/spawn`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agentPath:t})})).json();new r.Notice(`Agent queued: ${(e=a.queueId)==null?void 0:e.substring(0,8)}...`),this.currentTab="activity",await this.refreshQueue()}catch(n){new r.Notice(`Error: ${n.message}`)}}renderActivityTab(t){let e=t.createDiv({cls:"pilot-section-header"});if(e.createEl("h3",{text:"Agent Activity"}),e.createEl("button",{text:"Refresh",cls:"pilot-btn-small"}).addEventListener("click",()=>this.refreshQueue()),this.queueState.running.length>0){let o=t.createDiv({cls:"pilot-section"});o.createEl("h4",{text:`Running (${this.queueState.running.length})`,cls:"pilot-section-title running"});for(let c of this.queueState.running)this.renderQueueItem(o,c,"running")}if(this.queueState.pending.length>0){let o=t.createDiv({cls:"pilot-section"});o.createEl("h4",{text:`Pending (${this.queueState.pending.length})`,cls:"pilot-section-title pending"});for(let c of this.queueState.pending)this.renderQueueItem(o,c,"pending")}let a=t.createDiv({cls:"pilot-section"});if(a.createEl("h4",{text:`Completed (${this.queueState.completed.length})`,cls:"pilot-section-title completed"}),this.queueState.completed.length===0)a.createDiv({cls:"pilot-empty",text:"No completed agents yet"});else{let o=[...this.queueState.completed].reverse().slice(0,10);for(let c of o)this.renderQueueItem(a,c,"completed")}}renderQueueItem(t,e,n){var g,m,p;let a=t.createDiv({cls:`pilot-queue-item pilot-queue-${n}`}),o=a.createDiv({cls:"pilot-queue-header"}),c=e.agentPath.replace("agents/","").replace(".md","");o.createEl("span",{text:c,cls:"pilot-queue-name"});let i=o.createEl("span",{cls:`pilot-status-badge pilot-status-${n}`,text:n});n==="running"&&i.addClass("pilot-spinning"),(g=e.context)!=null&&g.documentPath&&a.createEl("div",{cls:"pilot-queue-target",text:`\u2192 ${e.context.documentPath}`});let l=a.createDiv({cls:"pilot-queue-timing"});if((m=e.result)!=null&&m.durationMs)l.createEl("span",{text:`${(e.result.durationMs/1e3).toFixed(1)}s`});else if(e.startedAt){let u=Math.floor((Date.now()-new Date(e.startedAt).getTime())/1e3);l.createEl("span",{text:`${u}s elapsed...`,cls:"pilot-elapsed"})}if(n==="completed"&&((p=e.result)!=null&&p.response)){a.createDiv({cls:"pilot-queue-preview"}).createEl("div",{text:e.result.response.substring(0,200)+(e.result.response.length>200?"...":""),cls:"pilot-preview-text"});let h=a.createDiv({cls:"pilot-queue-actions"});h.createEl("button",{text:"View Full",cls:"pilot-btn-small"}).addEventListener("click",()=>{new w(this.app,c,e.result.response).open()}),h.createEl("button",{text:"Follow Up",cls:"pilot-btn-small pilot-btn-followup"}).addEventListener("click",()=>{this.startFollowUp(e)})}e.error&&a.createDiv({cls:"pilot-queue-error",text:`Error: ${e.error}`})}async refreshQueue(){try{let e=await(await fetch(`${this.plugin.settings.orchestratorUrl}/api/queue`)).json();if(this.queueState={running:e.running||[],completed:e.completed||[],pending:e.pending||[]},this.currentTab==="activity"){let n=this.containerEl.querySelector(".pilot-content"),a=(n==null?void 0:n.scrollTop)||0;this.render();let o=this.containerEl.querySelector(".pilot-content");o&&(o.scrollTop=a)}else{let n=this.containerEl.querySelector(".pilot-tabs");if(n){let a=n.querySelectorAll(".pilot-tab")[2],o=a==null?void 0:a.querySelector(".pilot-badge");o&&(o.textContent=String(this.queueState.running.length),o.toggleClass("hidden",this.queueState.running.length===0))}}}catch(t){console.error("Failed to refresh queue:",t)}}addStyles(){let t="agent-pilot-styles";if(document.getElementById(t))return;let e=document.createElement("style");e.id=t,e.textContent=`
      .agent-pilot-view {
        display: flex;
        flex-direction: column;
        height: 100%;
      }

      .pilot-header {
        padding: 8px;
        border-bottom: 1px solid var(--background-modifier-border);
      }

      .pilot-tabs {
        display: flex;
        gap: 4px;
      }

      .pilot-tab {
        flex: 1;
        padding: 8px 12px;
        background: var(--background-secondary);
        border: none;
        border-radius: 4px;
        cursor: pointer;
        font-size: 13px;
        position: relative;
      }

      .pilot-tab.active {
        background: var(--interactive-accent);
        color: var(--text-on-accent);
      }

      .pilot-badge {
        position: absolute;
        top: -4px;
        right: -4px;
        background: var(--text-error);
        color: white;
        font-size: 10px;
        padding: 2px 6px;
        border-radius: 10px;
        min-width: 16px;
        text-align: center;
      }

      .pilot-badge.hidden {
        display: none;
      }

      .pilot-content {
        flex: 1;
        overflow-y: auto;
        padding: 12px;
      }

      /* Chat styles */
      .pilot-selector-row {
        display: flex;
        align-items: center;
        gap: 8px;
        margin-bottom: 12px;
      }

      .pilot-label {
        font-size: 12px;
        color: var(--text-muted);
      }

      .pilot-select {
        flex: 1;
        padding: 4px 8px;
        border-radius: 4px;
        background: var(--background-secondary);
        border: 1px solid var(--background-modifier-border);
      }

      .pilot-messages {
        flex: 1;
        min-height: 200px;
        max-height: 400px;
        overflow-y: auto;
        margin-bottom: 12px;
      }

      .pilot-message {
        margin-bottom: 12px;
        padding: 10px 12px;
        border-radius: 8px;
        max-width: 90%;
      }

      .pilot-message-user {
        background: var(--interactive-accent);
        color: var(--text-on-accent);
        margin-left: auto;
      }

      .pilot-message-assistant {
        background: var(--background-secondary);
      }

      .pilot-message-system {
        background: var(--background-modifier-border);
        font-size: 12px;
        opacity: 0.8;
        text-align: center;
        margin: 8px auto;
        max-width: 100%;
      }

      .pilot-message-agent {
        font-size: 11px;
        opacity: 0.7;
        margin-bottom: 4px;
      }

      .pilot-message-content {
        white-space: pre-wrap;
        word-break: break-word;
      }

      .pilot-message-time {
        font-size: 10px;
        opacity: 0.5;
        margin-top: 4px;
      }

      .pilot-input-area {
        display: flex;
        gap: 8px;
      }

      .pilot-input {
        flex: 1;
        min-height: 60px;
        padding: 8px;
        border-radius: 8px;
        background: var(--background-secondary);
        border: 1px solid var(--background-modifier-border);
        resize: none;
      }

      .pilot-send {
        padding: 8px 16px;
        background: var(--interactive-accent);
        color: var(--text-on-accent);
        border: none;
        border-radius: 8px;
        cursor: pointer;
      }

      /* Agent cards */
      .pilot-section-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 12px;
      }

      .pilot-section-header h3 {
        margin: 0;
        font-size: 14px;
      }

      .pilot-agent-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .pilot-agent-card {
        padding: 12px;
        background: var(--background-secondary);
        border-radius: 8px;
        border: 1px solid var(--background-modifier-border);
      }

      .pilot-agent-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 8px;
      }

      .pilot-agent-name {
        font-weight: 600;
      }

      .pilot-type-badge {
        font-size: 10px;
        padding: 2px 8px;
        border-radius: 10px;
        text-transform: uppercase;
      }

      .pilot-type-chatbot {
        background: var(--interactive-accent);
        color: var(--text-on-accent);
      }

      .pilot-type-doc {
        background: #22c55e;
        color: white;
      }

      .pilot-type-standalone {
        background: #f59e0b;
        color: white;
      }

      .pilot-agent-section {
        margin-bottom: 20px;
      }

      .pilot-section-hint {
        font-size: 11px;
        color: var(--text-muted);
        margin-bottom: 8px;
      }

      .pilot-agent-list {
        display: flex;
        flex-direction: column;
        gap: 8px;
      }

      .pilot-agent-desc {
        font-size: 12px;
        color: var(--text-muted);
        margin-bottom: 8px;
      }

      .pilot-agent-path {
        font-size: 11px;
        font-family: monospace;
        opacity: 0.6;
        margin-bottom: 8px;
      }

      .pilot-agent-actions {
        display: flex;
        gap: 8px;
      }

      /* Activity/Queue styles */
      .pilot-section {
        margin-bottom: 16px;
      }

      .pilot-section-title {
        font-size: 12px;
        text-transform: uppercase;
        margin-bottom: 8px;
        padding-bottom: 4px;
        border-bottom: 2px solid var(--background-modifier-border);
      }

      .pilot-section-title.running {
        border-color: var(--text-accent);
        color: var(--text-accent);
      }

      .pilot-section-title.completed {
        border-color: var(--text-success);
        color: var(--text-success);
      }

      .pilot-section-title.pending {
        border-color: var(--text-muted);
      }

      .pilot-queue-item {
        padding: 10px;
        background: var(--background-secondary);
        border-radius: 6px;
        margin-bottom: 8px;
        border-left: 3px solid var(--background-modifier-border);
      }

      .pilot-queue-running {
        border-left-color: var(--text-accent);
      }

      .pilot-queue-completed {
        border-left-color: var(--text-success);
      }

      .pilot-queue-header {
        display: flex;
        justify-content: space-between;
        align-items: center;
        margin-bottom: 4px;
      }

      .pilot-queue-name {
        font-weight: 500;
      }

      .pilot-status-badge {
        font-size: 10px;
        padding: 2px 8px;
        border-radius: 10px;
      }

      .pilot-status-running {
        background: var(--text-accent);
        color: white;
      }

      .pilot-status-completed {
        background: var(--text-success);
        color: white;
      }

      .pilot-status-pending {
        background: var(--text-muted);
        color: white;
      }

      .pilot-spinning::before {
        content: '';
        display: inline-block;
        width: 8px;
        height: 8px;
        border: 2px solid white;
        border-top-color: transparent;
        border-radius: 50%;
        margin-right: 4px;
        animation: spin 1s linear infinite;
      }

      @keyframes spin {
        to { transform: rotate(360deg); }
      }

      .pilot-queue-timing {
        font-size: 11px;
        color: var(--text-muted);
      }

      .pilot-elapsed {
        color: var(--text-accent);
      }

      .pilot-queue-preview {
        margin-top: 8px;
        padding: 8px;
        background: var(--background-primary);
        border-radius: 4px;
        font-size: 12px;
      }

      .pilot-preview-text {
        color: var(--text-muted);
        white-space: pre-wrap;
      }

      .pilot-queue-error {
        margin-top: 8px;
        padding: 8px;
        background: rgba(255, 0, 0, 0.1);
        border-radius: 4px;
        font-size: 12px;
        color: var(--text-error);
      }

      .pilot-queue-target {
        font-size: 11px;
        color: var(--text-muted);
        font-family: monospace;
        margin-top: 4px;
      }

      .pilot-queue-actions {
        display: flex;
        gap: 8px;
        margin-top: 8px;
      }

      .pilot-btn-followup {
        background: var(--interactive-accent);
        color: var(--text-on-accent);
      }

      /* Buttons */
      .pilot-btn-small {
        padding: 4px 12px;
        font-size: 11px;
        background: var(--background-modifier-border);
        border: none;
        border-radius: 4px;
        cursor: pointer;
      }

      .pilot-btn-primary {
        padding: 6px 16px;
        background: var(--interactive-accent);
        color: var(--text-on-accent);
        border: none;
        border-radius: 4px;
        cursor: pointer;
      }

      .pilot-empty {
        text-align: center;
        color: var(--text-muted);
        padding: 20px;
        font-size: 13px;
      }
    `,document.head.appendChild(e)}},w=class extends r.Modal{constructor(s,t,e){super(s),this.agentName=t,this.response=e}onOpen(){let{contentEl:s}=this;s.empty(),s.createEl("h2",{text:`${this.agentName} Result`});let t=s.createDiv({cls:"result-response"});t.style.cssText=`
      white-space: pre-wrap;
      background: var(--background-secondary);
      padding: 16px;
      border-radius: 8px;
      max-height: 400px;
      overflow-y: auto;
      font-size: 13px;
    `,t.textContent=this.response;let e=s.createEl("button",{text:"Close"});e.style.cssText="margin-top: 16px; padding: 8px 24px;",e.addEventListener("click",()=>this.close())}onClose(){let{contentEl:s}=this;s.empty()}},E=class extends r.PluginSettingTab{constructor(s,t){super(s,t),this.plugin=t}display(){let{containerEl:s}=this;s.empty(),s.createEl("h2",{text:"Agent Pilot Settings"}),new r.Setting(s).setName("Orchestrator URL").setDesc("URL of your Agent Pilot orchestrator server").addText(a=>a.setPlaceholder("http://localhost:3333").setValue(this.plugin.settings.orchestratorUrl).onChange(async o=>{this.plugin.settings.orchestratorUrl=o,await this.plugin.saveSettings()})),new r.Setting(s).setName("Auto-refresh Activity").setDesc("Automatically refresh agent activity status").addToggle(a=>a.setValue(this.plugin.settings.autoRefreshQueue).onChange(async o=>{this.plugin.settings.autoRefreshQueue=o,await this.plugin.saveSettings()})),new r.Setting(s).setName("Refresh Interval").setDesc("How often to refresh activity (in milliseconds)").addText(a=>a.setValue(String(this.plugin.settings.refreshInterval)).onChange(async o=>{this.plugin.settings.refreshInterval=parseInt(o)||3e3,await this.plugin.saveSettings()}));let t=s.createDiv({cls:"setting-item"}),e=t.createEl("button",{text:"Test Connection"}),n=t.createEl("span");n.style.marginLeft="10px",e.addEventListener("click",async()=>{n.textContent="Testing...";try{let a=await fetch(`${this.plugin.settings.orchestratorUrl}/api/vault`);if(a.ok){let o=await a.json();n.textContent=`Connected! ${o.totalDocuments} docs, ${o.totalAgents} agents`,n.style.color="var(--text-success)"}else throw new Error(`HTTP ${a.status}`)}catch(a){n.textContent=`Failed: ${a.message}`,n.style.color="var(--text-error)"}})}},f=class extends r.Plugin{async onload(){await this.loadSettings(),this.registerView(v,s=>new y(s,this)),this.addRibbonIcon("bot","Agent Pilot",()=>{this.activateView()}),this.addCommand({id:"open-pilot",name:"Open Agent Pilot",callback:()=>this.activateView()}),this.addCommand({id:"run-agent",name:"Run Agent",callback:()=>new A(this.app,this).open()}),this.addCommand({id:"run-agents",name:"Run Agents on Current Document",callback:()=>{let s=this.app.workspace.getActiveFile();if(!s||!s.path.endsWith(".md")){new r.Notice("Please open a markdown file first");return}new k(this.app,this,s.path).open()}}),this.addCommand({id:"manage-agents",name:"Manage Document Agents",callback:()=>{let s=this.app.workspace.getActiveFile();if(!s||!s.path.endsWith(".md")){new r.Notice("Please open a markdown file first");return}new P(this.app,this,s.path).open()}}),this.addSettingTab(new E(this.app,this)),console.log("Agent Pilot plugin loaded")}async onunload(){console.log("Agent Pilot plugin unloaded")}async loadSettings(){this.settings=Object.assign({},B,await this.loadData())}async saveSettings(){await this.saveData(this.settings)}async activateView(){let{workspace:s}=this.app,t=s.getLeavesOfType(v)[0];if(!t){let e=s.getRightLeaf(!1);e&&(t=e,await t.setViewState({type:v,active:!0}))}t&&s.revealLeaf(t)}},A=class extends r.Modal{constructor(s,t){super(s),this.plugin=t}async onOpen(){let{contentEl:s}=this;s.empty(),s.createEl("h2",{text:"Run Agent"});let t=this.app.workspace.getActiveFile();try{let n=await(await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents`)).json(),a=n.filter(i=>i.type==="doc"),o=n.filter(i=>i.type==="standalone");if(a.length>0){s.createEl("h3",{text:"Document Agents",cls:"quick-spawn-section"}),t?s.createEl("p",{text:`Will run on: ${t.name}`,cls:"quick-spawn-hint"}):s.createEl("p",{text:"Open a document first to run these",cls:"quick-spawn-hint"});for(let i of a){let l=s.createEl("button",{text:i.name,cls:t?"mod-cta":""});l.style.cssText="display: block; width: 100%; margin-bottom: 8px;",t||(l.disabled=!0),l.addEventListener("click",async()=>{t&&(await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents/spawn`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agentPath:i.path,message:"Process this document.",context:{documentPath:t.path}})}),new r.Notice(`Running ${i.name} on ${t.name}`),this.close())})}}if(o.length>0){s.createEl("h3",{text:"Standalone Agents",cls:"quick-spawn-section"});for(let i of o){let l=s.createEl("button",{text:i.name,cls:"mod-cta"});l.style.cssText="display: block; width: 100%; margin-bottom: 8px;",l.addEventListener("click",async()=>{await fetch(`${this.plugin.settings.orchestratorUrl}/api/agents/spawn`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agentPath:i.path})}),new r.Notice(`Running: ${i.name}`),this.close()})}}a.length===0&&o.length===0&&s.createEl("p",{text:"No doc or standalone agents available"});let c=s.createEl("style");c.textContent=`
        .quick-spawn-section { margin-top: 16px; margin-bottom: 8px; font-size: 14px; }
        .quick-spawn-hint { font-size: 12px; color: var(--text-muted); margin-bottom: 8px; }
      `}catch(e){s.createEl("p",{text:`Error: ${e.message}`})}}onClose(){let{contentEl:s}=this;s.empty()}},k=class extends r.Modal{constructor(t,e,n){super(t);this.agents=[];this.selectedAgents=new Set;this.plugin=e,this.documentPath=n}async onOpen(){let{contentEl:t}=this;t.empty(),t.addClass("run-agents-modal"),t.createEl("h2",{text:"Run Agents"}),t.createEl("p",{text:`Document: ${this.documentPath}`,cls:"run-agents-path"});let e=t.createDiv({text:"Loading agents..."});try{let a=await(await fetch(`${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/agents`)).json();if(this.agents=a,e.remove(),a.length===0){t.createEl("p",{text:"No agents configured for this document.",cls:"run-agents-empty"}),t.createEl("p",{text:'Add an "agents" array to the document frontmatter to configure agents.',cls:"run-agents-hint"});return}let o=t.createDiv({cls:"run-agents-list"});for(let p of a){let u=o.createDiv({cls:"run-agents-row"}),h=u.createEl("input",{type:"checkbox"});h.checked=p.status==="pending"||p.status==="needs_run",h.checked&&this.selectedAgents.add(p.path),h.addEventListener("change",()=>{h.checked?this.selectedAgents.add(p.path):this.selectedAgents.delete(p.path)});let x=u.createDiv({cls:"run-agents-label"}),S=p.path.replace("agents/","").replace(".md","");x.createEl("span",{text:S,cls:"run-agents-name"});let z=x.createEl("span",{cls:`run-agents-status run-agents-status-${p.status}`,text:p.status});if(p.triggerRaw&&x.createEl("span",{cls:"run-agents-trigger",text:p.triggerRaw}),p.lastRun){let T=new Date(p.lastRun);x.createEl("span",{cls:"run-agents-lastrun",text:`Last: ${T.toLocaleDateString()} ${T.toLocaleTimeString()}`})}}let c=t.createDiv({cls:"run-agents-actions"});c.createEl("button",{text:"Select All",cls:"mod-cta"}).addEventListener("click",()=>{this.selectedAgents.clear();for(let p of this.agents)this.selectedAgents.add(p.path);o.querySelectorAll('input[type="checkbox"]').forEach(p=>{p.checked=!0})}),c.createEl("button",{text:"Select None"}).addEventListener("click",()=>{this.selectedAgents.clear(),o.querySelectorAll('input[type="checkbox"]').forEach(p=>{p.checked=!1})}),c.createEl("button",{text:"Run Selected",cls:"mod-warning"}).addEventListener("click",()=>this.runSelected()),c.createEl("button",{text:"Run All Pending",cls:"mod-cta"}).addEventListener("click",()=>this.runAllPending()),this.addModalStyles()}catch(n){e.textContent=`Error: ${n.message}`}}async runSelected(){if(this.selectedAgents.size===0){new r.Notice("No agents selected");return}try{let e=await(await fetch(`${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/run-agents`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({agents:Array.from(this.selectedAgents)})})).json();new r.Notice(`Started ${e.ran} agent(s)`),this.close()}catch(t){new r.Notice(`Error: ${t.message}`)}}async runAllPending(){try{let e=await(await fetch(`${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/run-agents`,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({})})).json();new r.Notice(`Started ${e.ran} agent(s)`),this.close()}catch(t){new r.Notice(`Error: ${t.message}`)}}addModalStyles(){let t="run-agents-modal-styles";if(document.getElementById(t))return;let e=document.createElement("style");e.id=t,e.textContent=`
      .run-agents-modal {
        max-width: 500px;
      }

      .run-agents-path {
        color: var(--text-muted);
        font-size: 12px;
        font-family: monospace;
      }

      .run-agents-empty {
        color: var(--text-muted);
        font-style: italic;
      }

      .run-agents-hint {
        font-size: 12px;
        color: var(--text-muted);
      }

      .run-agents-list {
        margin: 16px 0;
        max-height: 300px;
        overflow-y: auto;
      }

      .run-agents-row {
        display: flex;
        align-items: flex-start;
        gap: 12px;
        padding: 8px;
        background: var(--background-secondary);
        border-radius: 4px;
        margin-bottom: 8px;
      }

      .run-agents-row input[type="checkbox"] {
        margin-top: 4px;
      }

      .run-agents-label {
        flex: 1;
        display: flex;
        flex-direction: column;
        gap: 4px;
      }

      .run-agents-name {
        font-weight: 600;
      }

      .run-agents-status {
        display: inline-block;
        font-size: 10px;
        padding: 2px 8px;
        border-radius: 10px;
        text-transform: uppercase;
        margin-left: 8px;
      }

      .run-agents-status-pending {
        background: var(--text-muted);
        color: white;
      }

      .run-agents-status-needs_run {
        background: var(--text-accent);
        color: white;
      }

      .run-agents-status-running {
        background: var(--text-accent);
        color: white;
      }

      .run-agents-status-completed {
        background: var(--text-success);
        color: white;
      }

      .run-agents-status-error {
        background: var(--text-error);
        color: white;
      }

      .run-agents-trigger {
        font-size: 11px;
        color: var(--text-muted);
        font-family: monospace;
      }

      .run-agents-lastrun {
        font-size: 11px;
        color: var(--text-muted);
      }

      .run-agents-actions {
        display: flex;
        gap: 8px;
        flex-wrap: wrap;
        margin-top: 16px;
      }

      .run-agents-actions button {
        padding: 8px 16px;
      }
    `,document.head.appendChild(e)}onClose(){let{contentEl:t}=this;t.empty()}},P=class extends r.Modal{constructor(t,e,n){super(t);this.documentAgents=[];this.availableAgents=[];this.plugin=e,this.documentPath=n}async onOpen(){let{contentEl:t}=this;t.empty(),t.addClass("manage-agents-modal"),t.createEl("h2",{text:"Manage Document Agents"}),t.createEl("p",{text:this.documentPath,cls:"manage-agents-path"});let e=t.createDiv({text:"Loading..."});try{let[n,a]=await Promise.all([fetch(`${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/agents`),fetch(`${this.plugin.settings.orchestratorUrl}/api/agents`)]);this.documentAgents=await n.json(),this.availableAgents=await a.json(),e.remove(),this.renderContent()}catch(n){e.textContent=`Error: ${n.message}`}}renderContent(){let{contentEl:t}=this,e=t.querySelector(".manage-agents-content");e&&e.remove();let n=t.createDiv({cls:"manage-agents-content"});if(n.createEl("h3",{text:"Configured Agents"}),this.documentAgents.length===0)n.createEl("p",{text:"No agents configured. Add one below!",cls:"manage-agents-empty"});else{let u=n.createDiv({cls:"manage-agents-list"});for(let h=0;h<this.documentAgents.length;h++){let x=this.documentAgents[h];this.renderAgentRow(u,x,h)}}n.createEl("h3",{text:"Add Agent",cls:"manage-agents-add-header"});let a=n.createDiv({cls:"manage-agents-add-row"}),o=a.createEl("select",{cls:"manage-agents-select"});o.createEl("option",{value:"",text:"Select an agent..."});let c=new Set(this.documentAgents.map(u=>u.path));for(let u of this.availableAgents)c.has(u.path)||o.createEl("option",{value:u.path,text:`${u.name} (${u.type||"chatbot"})`});let i=a.createEl("input",{type:"text",placeholder:"Trigger (optional)",cls:"manage-agents-trigger-input"});a.createEl("button",{text:"Add",cls:"mod-cta"}).addEventListener("click",()=>{if(!o.value){new r.Notice("Please select an agent");return}this.documentAgents.push({path:o.value,status:"pending",trigger:null,triggerRaw:i.value||null,lastRun:null,enabled:!0}),this.renderContent()});let g=n.createDiv({cls:"manage-agents-actions"});g.createEl("button",{text:"Save Changes",cls:"mod-cta"}).addEventListener("click",()=>this.saveChanges()),g.createEl("button",{text:"Cancel"}).addEventListener("click",()=>this.close()),this.addModalStyles()}renderAgentRow(t,e,n){let a=t.createDiv({cls:"manage-agents-row"}),o=a.createDiv({cls:"manage-agents-info"}),c=e.path.replace("agents/","").replace(".md","");o.createEl("span",{text:c,cls:"manage-agents-name"});let i=a.createDiv({cls:"manage-agents-trigger-container"});i.createEl("span",{text:"Trigger:",cls:"manage-agents-label"});let l=i.createEl("input",{type:"text",value:e.triggerRaw||"",placeholder:"manual",cls:"manage-agents-trigger-edit"});l.addEventListener("change",()=>{this.documentAgents[n].triggerRaw=l.value||null}),a.createEl("button",{text:"Remove",cls:"manage-agents-remove"}).addEventListener("click",()=>{this.documentAgents.splice(n,1),this.renderContent()})}async saveChanges(){try{let t=this.documentAgents.map(n=>({path:n.path,status:n.status||"pending",trigger:n.triggerRaw||null,enabled:n.enabled!==!1})),e=await fetch(`${this.plugin.settings.orchestratorUrl}/api/documents/${this.documentPath}/agents`,{method:"PUT",headers:{"Content-Type":"application/json"},body:JSON.stringify({agents:t})});if(e.ok)new r.Notice("Agents saved!"),this.close();else{let n=await e.json();new r.Notice(`Error: ${n.error}`)}}catch(t){new r.Notice(`Error: ${t.message}`)}}addModalStyles(){let t="manage-agents-modal-styles";if(document.getElementById(t))return;let e=document.createElement("style");e.id=t,e.textContent=`
      .manage-agents-modal { max-width: 600px; }
      .manage-agents-path { color: var(--text-muted); font-size: 12px; font-family: monospace; margin-bottom: 16px; }
      .manage-agents-content h3 { margin-top: 16px; margin-bottom: 8px; font-size: 14px; }
      .manage-agents-empty { color: var(--text-muted); font-style: italic; }
      .manage-agents-list { display: flex; flex-direction: column; gap: 8px; }
      .manage-agents-row { display: flex; align-items: center; gap: 12px; padding: 10px; background: var(--background-secondary); border-radius: 6px; }
      .manage-agents-info { flex: 1; }
      .manage-agents-name { font-weight: 600; }
      .manage-agents-trigger-container { display: flex; align-items: center; gap: 8px; }
      .manage-agents-label { font-size: 12px; color: var(--text-muted); }
      .manage-agents-trigger-edit { width: 120px; padding: 4px 8px; font-size: 12px; font-family: monospace; }
      .manage-agents-remove { padding: 4px 12px; background: var(--background-modifier-error); color: white; border: none; border-radius: 4px; font-size: 11px; cursor: pointer; }
      .manage-agents-add-header { margin-top: 24px !important; border-top: 1px solid var(--background-modifier-border); padding-top: 16px; }
      .manage-agents-add-row { display: flex; gap: 8px; align-items: center; }
      .manage-agents-select { flex: 1; padding: 8px; }
      .manage-agents-trigger-input { width: 140px; padding: 8px; font-family: monospace; font-size: 12px; }
      .manage-agents-actions { display: flex; gap: 8px; margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--background-modifier-border); }
      .manage-agents-actions button { padding: 8px 20px; }
    `,document.head.appendChild(e)}onClose(){let{contentEl:t}=this;t.empty()}};
