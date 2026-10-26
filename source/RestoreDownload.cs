using System;
using System.Linq;
using System.Collections.Generic;
using Mono.Cecil;
using Mono.Cecil.Cil;

public sealed class RestoreDownload {
    readonly ModuleDefinition source, target;
    readonly Dictionary<string, TypeDefinition> types = new Dictionary<string, TypeDefinition>();
    readonly Dictionary<string, MethodDefinition> methods = new Dictionary<string, MethodDefinition>();
    readonly Dictionary<string, FieldDefinition> fields = new Dictionary<string, FieldDefinition>();
    readonly List<string> changed = new List<string>();
    readonly Dictionary<GenericParameter,GenericParameter> genericParameters = new Dictionary<GenericParameter,GenericParameter>();
    readonly Dictionary<string,TypeDefinition> generatedTypes = new Dictionary<string,TypeDefinition>();
    readonly Dictionary<string,MethodDefinition> generatedMethods = new Dictionary<string,MethodDefinition>();
    readonly Dictionary<string,FieldDefinition> generatedFields = new Dictionary<string,FieldDefinition>();
    RestoreDownload(ModuleDefinition s, ModuleDefinition t) {
        source=s; target=t;
        foreach(var x in All(t.Types)) {
            types[x.FullName]=x;
            foreach(var m in x.Methods) methods[m.FullName]=m;
            foreach(var f in x.Fields) fields[f.FullName]=f;
        }
    }
    static IEnumerable<TypeDefinition> All(IEnumerable<TypeDefinition> roots) {
        foreach(var t in roots) { yield return t; foreach(var n in All(t.NestedTypes)) yield return n; }
    }
    static bool Closure(TypeReference type) {
        while(type is TypeSpecification)type=((TypeSpecification)type).ElementType;
        return type.Name.StartsWith("_Closure$",StringComparison.Ordinal);
    }
    static bool Generated(MethodDefinition method) {
        return Closure(method.DeclaringType)||method.Name.StartsWith("_Lambda$",StringComparison.Ordinal);
    }
    static string GeneratedName(string name) {
        return "__DownloadRestore_"+LauncherPatchEngine.Hash(System.Text.Encoding.UTF8.GetBytes(name)).Substring(0,16);
    }
    public static string[] RequiredMethods(ModuleDefinition module,string[] selected) {
        var all=All(module.Types).SelectMany(t=>t.Methods).ToDictionary(m=>m.FullName);
        var required=new HashSet<string>(selected);
        var queue=new Queue<MethodDefinition>();
        foreach(var name in selected) {
            MethodDefinition method;
            if(!all.TryGetValue(name,out method))throw new InvalidOperationException("Missing donor method: "+name);
            queue.Enqueue(method);
        }
        while(queue.Count>0) {
            var method=queue.Dequeue();
            if(!method.HasBody)continue;
            foreach(var instruction in method.Body.Instructions) {
                var member=instruction.Operand as MemberReference;
                if(member==null)continue;
                var reference=member as MethodReference;
                MethodDefinition dependency;
                if(reference!=null&&all.TryGetValue(reference.FullName,out dependency)&&Generated(dependency)&&required.Add(dependency.FullName))queue.Enqueue(dependency);
                var type=member as TypeReference;
                if(type==null)type=member.DeclaringType;
                if(type==null||!Closure(type))continue;
                var closure=All(module.Types).SingleOrDefault(t=>t.FullName==type.FullName);
                if(closure==null)throw new InvalidOperationException("Missing donor closure: "+type.FullName);
                foreach(var child in closure.Methods)if(required.Add(child.FullName))queue.Enqueue(child);
            }
        }
        return required.OrderBy(x=>x,StringComparer.Ordinal).ToArray();
    }
    static void AssertBody(MethodDefinition method) {
        if(!method.HasBody)return;
        var code=method.Body.Instructions.Where(i=>i.OpCode!=OpCodes.Nop).ToArray();
        if(code.Length==2&&code[0].OpCode==OpCodes.Ldnull&&code[1].OpCode==OpCodes.Throw)
            throw new InvalidOperationException("Donor dependency was stripped: "+method.FullName);
    }
    bool Local(TypeReference t) {
        while(t is TypeSpecification) t=((TypeSpecification)t).ElementType;
        return t.Scope == source || (t.Scope is AssemblyNameReference && t.Scope.Name==source.Assembly.Name.Name);
    }
    TypeReference T(TypeReference t) {
        var g=t as GenericInstanceType;
        if(g!=null) { var n=new GenericInstanceType(T(g.ElementType)); foreach(var a in g.GenericArguments)n.GenericArguments.Add(T(a)); return n; }
        var arr=t as ArrayType;
        if(arr!=null)return new ArrayType(T(arr.ElementType),arr.Rank);
        if(t is ByReferenceType)return new ByReferenceType(T(((ByReferenceType)t).ElementType));
        if(t is PointerType)return new PointerType(T(((PointerType)t).ElementType));
        var p=t as GenericParameter;
        if(p!=null) {
            GenericParameter mapped;
            if(genericParameters.TryGetValue(p,out mapped))return mapped;
            var owner=p.Owner as TypeReference;
            if(owner!=null) return T(owner).GenericParameters[p.Position];
            return p;
        }
        if(!Local(t))return target.ImportReference(t);
        TypeDefinition found;
        if(!Closure(t)) {
            if(types.TryGetValue(t.FullName,out found))return found;
            throw new Exception("Missing type: "+t.FullName);
        }
        if(generatedTypes.TryGetValue(t.FullName,out found))return found;
        var def=t.Resolve();
        if(def.HasGenericParameters)throw new Exception("Unsupported generic closure: "+t.FullName);
        var parent=(TypeDefinition)T(def.DeclaringType);
        var name=GeneratedName(def.FullName);
        if(parent.NestedTypes.Any(x=>x.Name==name))throw new Exception("Generated closure name already exists: "+name);
        found=new TypeDefinition(def.Namespace,name,def.Attributes,T(def.BaseType));
        parent.NestedTypes.Add(found); generatedTypes[def.FullName]=found;
        foreach(var f in def.Fields) {
            var nf=new FieldDefinition(f.Name,f.Attributes,T(f.FieldType));
            found.Fields.Add(nf); generatedFields[f.FullName]=nf;
        }
        foreach(var m in def.Methods) {
            var nm=new MethodDefinition(m.Name,m.Attributes,T(m.ReturnType));
            foreach(var a in m.Parameters) nm.Parameters.Add(new ParameterDefinition(a.Name,a.Attributes,T(a.ParameterType)));
            found.Methods.Add(nm); generatedMethods[m.FullName]=nm;
        }
        foreach(var m in def.Methods) if(m.HasBody) {AssertBody(m);Copy(m,generatedMethods[m.FullName]);}
        changed.Add("Restored closure "+def.FullName);
        return found;
    }
    FieldReference F(FieldReference f) {
        if(!Local(f.DeclaringType))return new FieldReference(f.Name,T(f.FieldType),T(f.DeclaringType));
        var owner=T(f.DeclaringType);
        FieldDefinition found;
        if(Closure(f.DeclaringType)) {
            if(generatedFields.TryGetValue(f.FullName,out found))return found;
            throw new Exception("Missing generated field: "+f.FullName);
        }
        if(fields.TryGetValue(f.FullName,out found))return found;
        if(f.DeclaringType is GenericInstanceType)return new FieldReference(f.Name,T(f.FieldType),owner);
        throw new Exception("Missing field: "+f.FullName);
    }
    MethodReference M(MethodReference m) {
        var gm=m as GenericInstanceMethod;
        if(gm!=null) {var n=new GenericInstanceMethod(M(gm.ElementMethod));foreach(var a in gm.GenericArguments)n.GenericArguments.Add(T(a));return n;}
        if(!Local(m.DeclaringType)) {
            var n=new MethodReference(m.Name,target.TypeSystem.Void,T(m.DeclaringType)) {HasThis=m.HasThis,ExplicitThis=m.ExplicitThis,CallingConvention=m.CallingConvention};
            foreach(var gp in m.GenericParameters) {var ng=new GenericParameter(gp.Name,n);n.GenericParameters.Add(ng);genericParameters[gp]=ng;}
            n.ReturnType=T(m.ReturnType);
            foreach(var a in m.Parameters)n.Parameters.Add(new ParameterDefinition(T(a.ParameterType)));
            return n;
        }
        var owner=T(m.DeclaringType);
        MethodDefinition found;
        if(generatedMethods.TryGetValue(m.FullName,out found))return found;
        bool generated=Closure(m.DeclaringType)||m.Name.StartsWith("_Lambda$",StringComparison.Ordinal);
        if(!generated&&methods.TryGetValue(m.FullName,out found))return found;
        if(m.DeclaringType is GenericInstanceType) {
            var n=new MethodReference(m.Name,T(m.ReturnType),owner) {HasThis=m.HasThis,ExplicitThis=m.ExplicitThis,CallingConvention=m.CallingConvention};
            foreach(var a in m.Parameters)n.Parameters.Add(new ParameterDefinition(T(a.ParameterType)));
            foreach(var gp in m.GenericParameters)n.GenericParameters.Add(new GenericParameter(gp.Name,n));
            return n;
        }
        if(!generated)throw new Exception("Missing method: "+m.FullName);
        var def=m.Resolve();
        AssertBody(def);
        if(def.HasGenericParameters)throw new Exception("Unsupported generic delegate: "+m.FullName);
        var name=GeneratedName(def.FullName);
        if(((TypeDefinition)owner).Methods.Any(x=>x.Name==name))throw new Exception("Generated method name already exists: "+name);
        found=new MethodDefinition(name,def.Attributes,T(def.ReturnType));
        foreach(var a in def.Parameters)found.Parameters.Add(new ParameterDefinition(a.Name,a.Attributes,T(a.ParameterType)));
        ((TypeDefinition)owner).Methods.Add(found); generatedMethods[m.FullName]=found;
        Copy(def,found); changed.Add("Restored delegate "+def.FullName);return found;
    }
    void Copy(MethodDefinition from,MethodDefinition to) {
        var body=new MethodBody(to) {InitLocals=from.Body.InitLocals,MaxStackSize=from.Body.MaxStackSize};to.Body=body;
        foreach(var v in from.Body.Variables)body.Variables.Add(new VariableDefinition(T(v.VariableType)));
        var map=new Dictionary<Instruction,Instruction>();
        foreach(var i in from.Body.Instructions){var n=Instruction.Create(OpCodes.Nop);n.OpCode=i.OpCode;body.Instructions.Add(n);map[i]=n;}
        foreach(var i in from.Body.Instructions) {
            object o=i.Operand;
            if(o is Instruction)o=map[(Instruction)o];
            else if(o is Instruction[])o=((Instruction[])o).Select(x=>map[x]).ToArray();
            else if(o is VariableDefinition)o=body.Variables[((VariableDefinition)o).Index];
            else if(o is ParameterDefinition)o=to.Parameters[((ParameterDefinition)o).Index];
            else if(o is TypeReference)o=T((TypeReference)o);
            else if(o is FieldReference)o=F((FieldReference)o);
            else if(o is MethodReference)o=M((MethodReference)o);
            else if(o is CallSite)throw new Exception("Unexpected calli");
            map[i].Operand=o;
        }
        foreach(var e in from.Body.ExceptionHandlers)body.ExceptionHandlers.Add(new ExceptionHandler(e.HandlerType) {
            CatchType=e.CatchType==null?null:T(e.CatchType),TryStart=map[e.TryStart],TryEnd=e.TryEnd==null?null:map[e.TryEnd],
            HandlerStart=map[e.HandlerStart],HandlerEnd=e.HandlerEnd==null?null:map[e.HandlerEnd],FilterStart=e.FilterStart==null?null:map[e.FilterStart]
        });
    }
    public static byte[] Run(byte[] donor,byte[] original,string[] selected) {
        return Run(donor,original,selected,null);
    }
    public static byte[] Run(byte[] donor,byte[] original,string[] selected,Action<ModuleDefinition> edit) {
        using(var resolver=new LauncherAssemblyResolver(original)) {
            var parameters=new ReaderParameters {AssemblyResolver=resolver};
            using(var a=AssemblyDefinition.ReadAssembly(new System.IO.MemoryStream(donor),parameters))using(var b=AssemblyDefinition.ReadAssembly(new System.IO.MemoryStream(original),parameters)) {
                var p=new RestoreDownload(a.MainModule,b.MainModule);
                var required=new HashSet<string>(RequiredMethods(a.MainModule,selected));
                foreach(var dependency in All(a.MainModule.Types).SelectMany(t=>t.Methods).Where(m=>required.Contains(m.FullName)))AssertBody(dependency);
                foreach(var name in selected) {
                    var m=All(a.MainModule.Types).SelectMany(x=>x.Methods).Single(x=>x.FullName==name);
                    MethodDefinition dest;
                    if(!p.methods.TryGetValue(m.FullName,out dest))throw new Exception("Missing destination: "+m.FullName);
                    p.Copy(m,dest);p.changed.Add("Restored "+m.FullName);
                }
                if(b.MainModule.AssemblyReferences.Any(x=>x.Name==a.Name.Name))throw new Exception("Accidental self reference");
                if(edit!=null)edit(b.MainModule);
                using(var output=new System.IO.MemoryStream()) {b.Write(output);return output.ToArray();}
            }
        }
    }
}
