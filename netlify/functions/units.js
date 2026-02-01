const { createClient } = require("@supabase/supabase-js");

const supabaseUrl = process.env.SUPABASE_URL;
const supabaseServiceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

exports.handler = async (event, context) => {
  if (!context.clientContext || !context.clientContext.user) {
    return {
      statusCode: 401,
      body: JSON.stringify({ error: "Unauthorized" }),
    };
  }

  if (!supabaseUrl || !supabaseServiceKey) {
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Missing Supabase env vars." }),
    };
  }

  const supabase = createClient(supabaseUrl, supabaseServiceKey, {
    auth: { persistSession: false },
  });

  const { data, error } = await supabase
    .from("units")
    .select("id,name,forms:forms(id,name,link,sort_order)")
    .order("name", { ascending: true })
    .order("sort_order", { foreignTable: "forms", ascending: true });

  if (error) {
    return {
      statusCode: 500,
      body: JSON.stringify({ error: error.message }),
    };
  }

  const units = (data || []).map((unit) => ({
    name: unit.name,
    forms: (unit.forms || []).map((form) => ({
      name: form.name,
      link: form.link,
      sort_order: form.sort_order,
    })),
  }));

  return {
    statusCode: 200,
    body: JSON.stringify({ units }),
  };
};
