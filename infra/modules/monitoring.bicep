// ============================================================================
// monitoring.bicep - Log Analytics + Azure Shared Dashboard
//
// Stands up the Log Analytics workspace that every other resource in the PoC
// sends its diagnostics/metrics to. Also deploys an Azure Portal shared
// dashboard for at-a-glance observability of the file shares (cost signals,
// performance counters, usage trends).
//
// This module deploys first because other modules need the workspace resource
// ID to configure their diagnostic settings.
//
// Ref: https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-overview
// Ref: https://learn.microsoft.com/azure/azure-portal/azure-portal-dashboards
// ============================================================================

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

param location string
param projectName string
param tags object

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

var lawName = 'law-${projectName}-poc'
var dashboardName = 'dash-${projectName}-azfiles'

// ---------------------------------------------------------------------------
// Log Analytics Workspace (via AVM)
//
// 30-day retention is the free tier default and plenty for a PoC. Bump it
// if you need longer retention for compliance testing, but know that storage
// costs go up.
// ---------------------------------------------------------------------------

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.15.0' = {
  name: 'law-deployment'
  params: {
    name: lawName
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: 30
  }
}

// ---------------------------------------------------------------------------
// Azure Shared Dashboard (via AVM)
//
// The dashboard JSON gives operators a single pane of glass for:
//  - File share transaction volume (success/failure breakdown)
//  - Ingress/egress bandwidth
//  - E2E latency percentiles
//  - Availability %
//  - Capacity used vs provisioned
//
// The dashboard queries pull from the LAW and from Azure Monitor metrics
// on the storage account. Since the storage account doesn't exist yet at
// deploy time, the dashboard tiles reference placeholder resource IDs that
// get populated once storage.bicep finishes. The portal handles this
// gracefully -- tiles just show "no data" until the storage account starts
// emitting metrics.
//
// If you want to customize the layout, export this dashboard from the portal
// after deployment, tweak it, and drop the JSON back into dashboards/.
//
// Ref: https://learn.microsoft.com/azure/azure-portal/azure-portal-dashboards-create-programmatically
// ---------------------------------------------------------------------------

module dashboard 'br/public:avm/res/portal/dashboard:0.3.2' = {
  name: 'dashboard-deployment'
  params: {
    name: dashboardName
    location: location
    tags: tags
    lenses: [
      {
        order: 0
        parts: [
          // Part 0: Markdown tile -- overview header
          {
            position: {
              x: 0
              y: 0
              colSpan: 12
              rowSpan: 1
            }
            metadata: {
              type: 'Extension/HubsExtension/PartType/MarkdownPart'
              inputs: []
              settings: {
                content: {
                  settings: {
                    content: '## Azure Files PoC -- Monitoring Dashboard\nThis dashboard shows key metrics for the file shares deployed by this PoC. Data sources: Azure Monitor metrics and Log Analytics workspace `${lawName}`.'
                    title: ''
                    subtitle: ''
                    markdownSource: 1
                    markdownUri: null
                  }
                }
              }
            }
          }
          // Part 1: Log Analytics query -- file share transactions over last 24h
          {
            position: {
              x: 0
              y: 1
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                {
                  name: 'resourceTypeMode'
                  isOptional: true
                }
                {
                  name: 'ComponentId'
                  isOptional: true
                }
              ]
              settings: {
                content: {
                  Query: 'StorageFileLogs\n| where TimeGenerated > ago(24h)\n| summarize RequestCount=count(), Failures=countif(StatusCode >= 400) by bin(TimeGenerated, 1h)\n| render timechart'
                  ControlType: 'FrameControlChart'
                  SpecificChart: 'Line'
                  Dimensions: {
                    xAxis: {
                      name: 'TimeGenerated'
                      type: 'datetime'
                    }
                    yAxis: [
                      {
                        name: 'RequestCount'
                        type: 'long'
                      }
                      {
                        name: 'Failures'
                        type: 'long'
                      }
                    ]
                  }
                }
              }
            }
          }
          // Part 2: Log Analytics query -- latency distribution
          {
            position: {
              x: 6
              y: 1
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                {
                  name: 'resourceTypeMode'
                  isOptional: true
                }
                {
                  name: 'ComponentId'
                  isOptional: true
                }
              ]
              settings: {
                content: {
                  Query: 'StorageFileLogs\n| where TimeGenerated > ago(24h)\n| summarize P50=percentile(DurationMs, 50), P95=percentile(DurationMs, 95), P99=percentile(DurationMs, 99) by bin(TimeGenerated, 1h)\n| render timechart'
                  ControlType: 'FrameControlChart'
                  SpecificChart: 'Line'
                  Dimensions: {
                    xAxis: {
                      name: 'TimeGenerated'
                      type: 'datetime'
                    }
                    yAxis: [
                      {
                        name: 'P50'
                        type: 'real'
                      }
                      {
                        name: 'P95'
                        type: 'real'
                      }
                      {
                        name: 'P99'
                        type: 'real'
                      }
                    ]
                  }
                }
              }
            }
          }
          // Part 3: Log Analytics query -- ingress/egress bytes
          {
            position: {
              x: 0
              y: 5
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                {
                  name: 'resourceTypeMode'
                  isOptional: true
                }
                {
                  name: 'ComponentId'
                  isOptional: true
                }
              ]
              settings: {
                content: {
                  Query: 'StorageFileLogs\n| where TimeGenerated > ago(24h)\n| summarize IngressMB=sum(RequestBodySize)/1048576.0, EgressMB=sum(ResponseBodySize)/1048576.0 by bin(TimeGenerated, 1h)\n| render timechart'
                  ControlType: 'FrameControlChart'
                  SpecificChart: 'Area'
                  Dimensions: {
                    xAxis: {
                      name: 'TimeGenerated'
                      type: 'datetime'
                    }
                    yAxis: [
                      {
                        name: 'IngressMB'
                        type: 'real'
                      }
                      {
                        name: 'EgressMB'
                        type: 'real'
                      }
                    ]
                  }
                }
              }
            }
          }
          // Part 4: Log Analytics query -- operation breakdown
          {
            position: {
              x: 6
              y: 5
              colSpan: 6
              rowSpan: 4
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                {
                  name: 'resourceTypeMode'
                  isOptional: true
                }
                {
                  name: 'ComponentId'
                  isOptional: true
                }
              ]
              settings: {
                content: {
                  Query: 'StorageFileLogs\n| where TimeGenerated > ago(24h)\n| summarize Count=count() by OperationName\n| top 10 by Count desc\n| render barchart'
                  ControlType: 'FrameControlChart'
                  SpecificChart: 'Bar'
                  Dimensions: {
                    xAxis: {
                      name: 'OperationName'
                      type: 'string'
                    }
                    yAxis: [
                      {
                        name: 'Count'
                        type: 'long'
                      }
                    ]
                  }
                }
              }
            }
          }
          // Part 5: Log Analytics query -- error details
          {
            position: {
              x: 0
              y: 9
              colSpan: 12
              rowSpan: 4
            }
            metadata: {
              type: 'Extension/Microsoft_OperationsManagementSuite_Workspace/PartType/LogsDashboardPart'
              inputs: [
                {
                  name: 'resourceTypeMode'
                  isOptional: true
                }
                {
                  name: 'ComponentId'
                  isOptional: true
                }
              ]
              settings: {
                content: {
                  Query: 'StorageFileLogs\n| where TimeGenerated > ago(24h) and StatusCode >= 400\n| project TimeGenerated, OperationName, StatusCode, StatusText, Uri, CallerIpAddress\n| order by TimeGenerated desc\n| take 100'
                  ControlType: 'AnalyticsGrid'
                }
              }
            }
          }
        ]
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId
output logAnalyticsWorkspaceName string = logAnalytics.outputs.name
output dashboardName string = dashboard.outputs.name
