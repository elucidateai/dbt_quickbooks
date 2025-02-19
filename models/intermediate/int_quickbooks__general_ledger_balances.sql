with general_ledger as (
    select *
    from {{ref('quickbooks__general_ledger')}}
),

gl_accounting_periods as (
    select *
    from {{ref('int_quickbooks__general_ledger_date_spine')}}
),

gl_period_balance as (
    select
        account_id,
        account_number,
        account_name,
        is_sub_account,
        parent_account_number,
        parent_account_name,
        account_type,
        account_sub_type,
        financial_statement_helper,
        account_class,
        cast({{ dbt_utils.date_trunc("year", "transaction_date") }} as date) as date_year,
        cast({{ dbt_utils.date_trunc("month", "transaction_date") }} as date) as date_month,
        round(sum(adjusted_amount),2) as period_balance
    from general_ledger

    {{ dbt_utils.group_by(12) }}
),

gl_cumulative_balance as (
    select
        *,
        case when financial_statement_helper = 'balance_sheet'
            then round(sum(period_balance) over (partition by account_id order by date_month, account_id rows unbounded preceding),2) 
            else 0
                end as cumulative_balance
    from gl_period_balance
),

gl_beginning_balance as (
    select
        account_id,
        account_number,
        account_name,
        is_sub_account,
        parent_account_number,
        parent_account_name,
        account_type,
        account_sub_type,
        financial_statement_helper,
        account_class,
        date_year,
        date_month, 
        period_balance as period_net_change,
        case when financial_statement_helper = 'balance_sheet'
            then round((cumulative_balance - period_balance),2) 
            else 0
                end as period_beginning_balance,
        round(cumulative_balance,2) as period_ending_balance  
    from gl_cumulative_balance
),

gl_patch as (
    select 
        coalesce(gl_beginning_balance.account_id, gl_accounting_periods.account_id) as account_id,
        coalesce(gl_beginning_balance.account_number, gl_accounting_periods.account_number) as account_number,
        coalesce(gl_beginning_balance.account_name, gl_accounting_periods.account_name) as account_name,
        coalesce(gl_beginning_balance.is_sub_account, gl_accounting_periods.is_sub_account) as is_sub_account,
        coalesce(gl_beginning_balance.parent_account_number, gl_accounting_periods.parent_account_number) as parent_account_number,
        coalesce(gl_beginning_balance.parent_account_name, gl_accounting_periods.parent_account_name) as parent_account_name,
        coalesce(gl_beginning_balance.account_type, gl_accounting_periods.account_type) as account_type,
        coalesce(gl_beginning_balance.account_sub_type, gl_accounting_periods.account_sub_type) as account_sub_type,
        coalesce(gl_beginning_balance.account_class, gl_accounting_periods.account_class) as account_class,
        coalesce(gl_beginning_balance.financial_statement_helper, gl_accounting_periods.financial_statement_helper) as financial_statement_helper,
        coalesce(gl_beginning_balance.date_year, gl_accounting_periods.date_year) as date_year,
        gl_accounting_periods.period_first_day,
        gl_accounting_periods.period_last_day,
        gl_accounting_periods.period_index,
        gl_beginning_balance.period_net_change,
        gl_beginning_balance.period_beginning_balance,
        gl_beginning_balance.period_ending_balance,
        case when gl_beginning_balance.period_beginning_balance is null and period_index = 1
            then 0
            else gl_beginning_balance.period_beginning_balance
                end as period_beginning_balance_starter,
        case when gl_beginning_balance.period_ending_balance is null and period_index = 1
            then 0
            else gl_beginning_balance.period_ending_balance
                end as period_ending_balance_starter
    from gl_accounting_periods

    left join gl_beginning_balance
        on gl_beginning_balance.account_id = gl_accounting_periods.account_id
            and gl_beginning_balance.date_month = gl_accounting_periods.period_first_day
            and gl_beginning_balance.date_year = gl_accounting_periods.date_year
),

gl_value_partion as (
    select
        *,
        sum(case when period_ending_balance_starter is null 
            then 0 
            else 1 
                end) over (order by account_id, period_last_day rows unbounded preceding) as gl_partition
    from gl_patch

),
 
final as (
    select
        account_id,
        account_number,
        account_name,
        is_sub_account,
        parent_account_number,
        parent_account_name,
        account_type,
        account_sub_type,
        account_class,
        financial_statement_helper,
        date_year,
        period_first_day,
        period_last_day,
        coalesce(period_net_change,0) as period_net_change,
        coalesce(period_beginning_balance_starter,
            first_value(period_ending_balance_starter) over (partition by gl_partition order by period_last_day rows unbounded preceding)) as period_beginning_balance,
        coalesce(period_ending_balance_starter,
            first_value(period_ending_balance_starter) over (partition by gl_partition order by period_last_day rows unbounded preceding)) as period_ending_balance
    from gl_value_partion

)

select *
from final